import AppKit
import AVFoundation
import KoeCore
import SwiftUI
import UserNotifications

/// 全コンポーネントを束ねるコントローラ。MainActor 隔離＝実質 actor。
/// ステートマシンの Action を実処理にマップする。
@MainActor
@Observable
final class RecordingController {
    // UI へ公開する状態
    private(set) var isRecording = false
    private(set) var currentMode: RecordingMode = .raw
    private(set) var partialText = ""
    private(set) var audioLevel: Float = 0
    private(set) var isFinalizing = false
    /// 直近の書き起こし（履歴OFFでもメニューに出すメモリ上のバッファ）。挿入成功時のみ更新、newest first、最大3件。
    private(set) var recentTranscripts: [String] = []
    var settings = AppSettings()

    static let appSupportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Koe")
    static let replacementsURL = appSupportDir.appendingPathComponent("replacements.json")
    static let presetsURL = appSupportDir.appendingPathComponent("prompt-presets.json")

    private var machine = RecordingStateMachine()
    private let engine = AppleSpeechEngine()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let refinement = RefinementService()
    private let hud = RecordingHUDController()
    private var monitor: HotkeyMonitor?
    private var targetApp: NSRunningApplication?
    private var pendingTranscript = ""
    private var maxDurationTask: Task<Void, Never>?
    /// startSession() の完了（セッション公開）を表すタスク。マイクを先に開ける設計上、
    /// 公開前に停止・キャンセルが来ることがあるため、その完了を待ち合わせるのに使う。
    private var sessionStart: Task<AsyncStream<TranscriptUpdate>, Error>?
    private var refineDisabledNotified = false
    /// 直近に通知した整形フォールバック理由。同じ理由が連続する間は再通知しない。
    private var lastNotifiedFallbackReason: String?
    /// startCapture 時点でのAI整形有無のスナップショット。録音中に設定がトグルされても
    /// HUD 表示と実動作がズレないよう、stopAndFinalize はこの値を使う。
    private var sessionRefine = false
    /// startup() は MenuBarExtra の .task がメニューを開くたびに再実行され得るため、
    /// 一度だけ実行されるよう明示的にガードする。
    private var didStartup = false

    private let historyLogger = HistoryLogger(directory: RecordingController.appSupportDir)

    /// 現在のプリセットストアをディスクから読む（設定UIの変更を即反映するため毎回読む）
    func loadPresetStore() -> PromptPresetStore {
        PromptPresetStore.load(
            from: Self.presetsURL,
            legacyCustomInstruction: settings.legacyRefinementInstruction,
            storedSelectedID: settings.selectedPresetID)
    }

    func startup() async {
        guard !didStartup else { return }
        didStartup = true

        // プリセットのマイグレーションを確定させる（旧カスタム指示の取り込み等）。
        let store = loadPresetStore()
        try? store.save(to: Self.presetsURL)
        settings.selectedPresetID = store.selectedID.uuidString

        // 初回起動時: 必須権限が未許可なら権限案内ウィンドウを表示する。
        if !UserDefaults.standard.bool(forKey: "hasShownPermissionOnboarding") {
            let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if !CGPreflightListenEventAccess() || !CGPreflightPostEventAccess() || !micAuthorized {
                PermissionsWindow.show()
            }
            UserDefaults.standard.set(true, forKey: "hasShownPermissionOnboarding")
        }

        // ホットキー監視
        let m = HotkeyMonitor(config: .init(
            rawKeyCode: settings.rawHotkeyCode,
            refinedKeyCode: settings.refinedHotkeyCode))
        // HotkeyMonitor のコールバックは @Sendable（呼び出し側は既に .main キューに転送済み
        // だが型は nonisolated）。MainActor 隔離の self へは Task { @MainActor in ... } で戻す。
        m.onHotkey = { [weak self] mode, isDown, ts in
            Task { @MainActor in
                self?.handleHotkey(mode: mode, isDown: isDown, at: ts)
            }
        }
        m.onEscape = { [weak self] in
            Task { @MainActor in
                self?.dispatch(.escape)
            }
        }
        // shouldConsumeEscape は HotkeyMonitor のドキュメント上メイン runloop から呼ばれるため
        // MainActor.assumeIsolated が安全に成立する。
        m.shouldConsumeEscape = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.machine.state != .idle
            }
        }
        monitor = m
        _ = m.start()
        // AVAudioEngine の inputNode 初回アクセスは HAL / オーディオデバイスの初期化を伴い
        // 数百ms（Bluetooth や外部IFではさらに）かかる。初回ホットキーで払わないよう前倒しする。
        // 未許可の状態で触ると TCC プロンプトが不意に出るため、許可済みのときだけ。
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            _ = recorder.inputFormat
        }

        // モデル準備（失敗は通知のみ。自動リトライはせず、メニューの
        // 「音声モデルを再ダウンロード」から retryModelDownload() で手動再試行する）
        do {
            try await engine.prepare()
            // 準備できたら予熱まで済ませる（prepare はアセットの確認・DL だけで、
            // SpeechAnalyzer は作らないため、これが無いと初回 F9 でモデルロードを丸ごと払う）
            await engine.warmUp()
        } catch {
            notify("音声モデルの準備に失敗しました: \(error.localizedDescription)")
        }
    }

    /// メニューの「音声モデルを再ダウンロード」から呼ばれる。
    func retryModelDownload() {
        let engine = self.engine
        Task { @MainActor in
            do {
                try await engine.prepare()
                await engine.warmUp()
                self.notify("音声モデルの準備が完了しました")
            } catch {
                self.notify("音声モデルの準備に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    func reloadHotkeys() {
        monitor?.config = .init(
            rawKeyCode: settings.rawHotkeyCode,
            refinedKeyCode: settings.refinedHotkeyCode)
    }

    private func handleHotkey(mode: RecordingMode, isDown: Bool, at ts: Double) {
        dispatch(isDown ? .keyDown(mode: mode, at: ts) : .keyUp(mode: mode, at: ts))
    }

    private func dispatch(_ event: RecordingStateMachine.Event) {
        let action = machine.handle(event)
        switch action {
        case .startCapture(let mode):
            startCapture(mode: mode)
        case .stopAndFinalize:
            stopAndFinalize()
        case .cancel:
            cancelSession()
        case .beginRefining:
            beginRefining()
        case .beginInserting:
            beginInserting(text: pendingTranscript)
        case .insertRawInstead:
            beginInserting(text: pendingTranscript)
        case .none:
            break
        }
    }

    private func startCapture(mode: RecordingMode) {
        currentMode = mode
        partialText = ""
        targetApp = NSWorkspace.shared.frontmostApplication
        isRecording = true
        let effectiveRefine = mode == .refined && settings.aiRefinementEnabled
        sessionRefine = effectiveRefine
        if mode == .refined && !settings.aiRefinementEnabled && !refineDisabledNotified {
            notify("AI整形がOFFのため素のままで挿入します")
            refineDisabledNotified = true
        }
        hud.show(mode: effectiveRefine ? .refined : .raw)

        // AudioRecorder のコールバックは @Sendable（オーディオスレッドから呼ばれるため）。
        // MainActor 隔離クラスの stored property を @Sendable クロージャ内で直接読むことは
        // できないため、事前にローカルへ退避してからキャプチャする。
        let engine = self.engine

        // マイクは音声認識セッションの準備完了を待たずに先に開ける。
        // startSession() は analyzer.start()（音声モデルのロード）を含み、コールドスタートでは
        // 数百ms〜数秒かかる。これを待ってから録音を始めると、HUD が出ている間の発話が
        // 丸ごと失われて「認識が遅い」体感になるため、公開までの音声は engine 側に待避させ、
        // セッション公開時に順序どおり流し込む。
        engine.beginBuffering()
        engine.configureMicFormat(recorder.inputFormat)
        // @Sendable を明記する（MainActor 隔離コンテキストからの代入で MainActor 推論が
        // 効くと、オーディオスレッド実行時に dispatch_assert_queue_fail でクラッシュする。
        // docs/spike-results.md スパイクB 参照）。
        recorder.onBuffer = { @Sendable buffer in
            engine.feed(buffer)
        }
        recorder.onLevel = { @Sendable [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
                self?.hud.updateLevel(level)
            }
        }
        recorder.onDeviceChange = { [weak self] in
            Task { @MainActor in
                self?.notify("入力デバイスが変わったため録音をキャンセルしました")
                self?.dispatch(.failure)
            }
        }
        do {
            try recorder.start()
        } catch {
            engine.discardBuffered()
            notify("録音を開始できませんでした: \(error.localizedDescription)")
            dispatch(.failure)
            return
        }
        maxDurationTask = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self.dispatch(.maxDurationReached)
        }

        // セッション開始は別タスクで進める。停止・キャンセルはこのタスクの完了を
        // 待ち合わせる（sessionStart）ので、公開前に止めても待避音声は失われない。
        let start = Task { try await engine.startSession() }
        sessionStart = start
        Task {
            do {
                let updates = try await start.value
                // キャンセル後も stream が finish するまで最大1回 stale な partial が届き得るが、
                // engine 側のセッション guard（currentSession() 比較）により後続セッションの
                // 結果に紛れ込むことはなく実害なし。
                for await update in updates {
                    self.partialText = update.displayText
                    self.hud.updateText(update.displayText)
                }
            } catch {
                notify("音声認識を開始できませんでした: \(error.localizedDescription)")
                dispatch(.failure)
            }
        }
    }

    private func stopAndFinalize() {
        isRecording = false
        isFinalizing = true
        hud.showFinalizing()
        maxDurationTask?.cancel()
        recorder.stop()
        let start = sessionStart
        Task {
            // セッション公開前に停止された場合（モデルロード中の短い発話）に備え、開始完了を
            // 待ってから finalize する。待たずに finishAndTranscript すると notStarted となり、
            // 待避しておいた音声ごと失われる。
            if let start, (try? await start.value) == nil {
                dispatch(.failure)  // 開始自体が失敗（通知は startCapture 側で出している）
                return
            }
            do {
                let text = try await engine.finishAndTranscript()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let replaced = ReplacementDictionary.load(from: Self.replacementsURL).apply(to: text)
                if replaced.isEmpty {
                    dispatch(.failure)  // 空結果 → 静かにキャンセル
                } else {
                    pendingTranscript = replaced
                    dispatch(.transcriptReady(refine: sessionRefine))
                }
            } catch {
                notify("認識に失敗しました: \(error.localizedDescription)")
                dispatch(.failure)
            }
        }
    }

    private func cancelSession() {
        isRecording = false
        isFinalizing = false
        maxDurationTask?.cancel()
        recorder.stop()
        hud.hide()
        engine.discardBuffered()
        let start = sessionStart
        sessionStart = nil
        Task {
            // 開始途中なら公開まで待ってからキャンセルする。待たずに cancel すると、
            // 直後に公開されたセッションが誰にも止められないまま走り続ける。
            _ = try? await start?.value
            await engine.cancelSession()
        }
    }

    private func beginRefining() {
        hud.showRefining()
        let instruction = loadPresetStore().selected.instruction
        let modelID = settings.modelID
        Task {
            let (text, fallbackReason) = await refinement.refine(
                pendingTranscript, modelID: modelID, instruction: instruction)
            if let fallbackReason {
                if fallbackReason != lastNotifiedFallbackReason {
                    notify("AI整形をスキップしました（\(fallbackReason)）— 素のまま挿入します")
                    lastNotifiedFallbackReason = fallbackReason
                }
            } else {
                lastNotifiedFallbackReason = nil
            }
            pendingTranscript = text
            dispatch(.refinementFinished)
        }
    }

    private func beginInserting(text: String) {
        isFinalizing = false
        Task {
            let posted = await inserter.insert(text)
            if posted {
                recentTranscripts.insert(text, at: 0)
                if recentTranscripts.count > 3 { recentTranscripts.removeLast() }
                hud.hide()  // 完了演出は出さず静かに閉じる（毎回の表示は邪魔なため 2026-09-01 削除）
            } else {
                notify("貼り付けを送信できませんでした。テキストはクリップボードにあります")
                hud.hide()
            }
            if settings.historyEnabled {
                try? historyLogger.append(text: text, mode: currentMode.rawValue)
            }
            dispatch(.insertionFinished)
        }
    }

    private func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Koe"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
