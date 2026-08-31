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
    var settings = AppSettings()

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
    private var refineDisabledNotified = false
    /// 直近に通知した整形フォールバック理由。同じ理由が連続する間は再通知しない。
    private var lastNotifiedFallbackReason: String?
    /// startCapture 時点でのAI整形有無のスナップショット。録音中に設定がトグルされても
    /// HUD 表示と実動作がズレないよう、stopAndFinalize はこの値を使う。
    private var sessionRefine = false
    /// startup() は MenuBarExtra の .task がメニューを開くたびに再実行され得るため、
    /// 一度だけ実行されるよう明示的にガードする。
    private var didStartup = false

    private let historyLogger = HistoryLogger(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe"))

    func startup() async {
        guard !didStartup else { return }
        didStartup = true

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
        // モデル準備（失敗は通知のみ。自動リトライはせず、メニューの
        // 「音声モデルを再ダウンロード」から retryModelDownload() で手動再試行する）
        do { try await engine.prepare() } catch {
            notify("音声モデルの準備に失敗しました: \(error.localizedDescription)")
        }
    }

    /// メニューの「音声モデルを再ダウンロード」から呼ばれる。
    func retryModelDownload() {
        let engine = self.engine
        Task { @MainActor in
            do {
                try await engine.prepare()
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

        Task {
            do {
                engine.configureMicFormat(recorder.inputFormat)
                let updates = try await engine.startSession()
                recorder.onBuffer = { buffer in
                    engine.feed(buffer)
                }
                recorder.onLevel = { [weak self] level in
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
                try recorder.start()
                maxDurationTask = Task {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    self.dispatch(.maxDurationReached)
                }
                // キャンセル後も stream が finish するまで最大1回 stale な partial が届き得るが、
                // engine 側のセッション guard（currentSession() 比較）により後続セッションの
                // 結果に紛れ込むことはなく実害なし。
                for await update in updates {
                    self.partialText = update.displayText
                    self.hud.updateText(update.displayText)
                }
            } catch {
                notify("録音を開始できませんでした: \(error.localizedDescription)")
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
        Task {
            do {
                let text = try await engine.finishAndTranscript()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    dispatch(.failure)  // 空結果 → 静かにキャンセル
                } else {
                    pendingTranscript = text
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
        Task { await engine.cancelSession() }
    }

    private func beginRefining() {
        hud.showRefining()
        Task {
            let (text, fallbackReason) = await refinement.refine(pendingTranscript, settings: settings)
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
        hud.hide()
        let currentFront = NSWorkspace.shared.frontmostApplication
        if let targetApp, currentFront?.processIdentifier != targetApp.processIdentifier {
            notify("録音開始時のアプリと異なるアプリに挿入します")
        }
        Task {
            let posted = await inserter.insert(text)
            if !posted {
                notify("貼り付けを送信できませんでした。テキストはクリップボードにあります")
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
