import AppKit
import AVFoundation
import KoeCore
import KoeKit
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
    /// 直前に保存した参考音声（ポップオーバーの「直前の参考音声」用）。
    private(set) var lastReferenceRecording: ReferenceRecordingInfo?
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
    /// 録音終了後、AVAudioEngine を回したまま維持する猶予。連続入力時に
    /// CoreAudio のデバイス起動待ち（実測 約200-370ms）を毎回払わないための措置。
    /// 猶予中はマイクインジケータが点灯したままになるため、短めに切る。
    static let micKeepAlive: Duration = .seconds(30)
    private var keepAliveTask: Task<Void, Never>?
    /// 録音中のデバイス構成変更でエンジンを組み直しているタスク。
    /// 切替時は構成変更通知が短時間に連続して届く（実測: 5秒で3回）ため、合流させて1回にする。
    private var deviceRestartTask: Task<Void, Never>?
    private var refineDisabledNotified = false
    /// 固定マイク未接続の通知は、接続状態が戻るか設定を変えるまで1回だけ出す。
    private var preferredDeviceMissingNotified = false
    /// 直近に通知した整形フォールバック理由。同じ理由が連続する間は再通知しない。
    private var lastNotifiedFallbackReason: String?
    /// startCapture 時点でのAI整形有無のスナップショット。録音中に設定がトグルされても
    /// HUD 表示と実動作がズレないよう、stopAndFinalize はこの値を使う。
    private var sessionRefine = false
    /// startup() は MenuBarExtra の .task がメニューを開くたびに再実行され得るため、
    /// 一度だけ実行されるよう明示的にガードする。
    private var didStartup = false
    /// 録音中にセッションが異常終了（認識デーモン消滅など）した際、死んだセッションの
    /// 確定済みテキストをここへ引き継ぎ、再接続後のセッションの結果と連結する。
    private var carriedTranscript = ""
    /// 1回の録音内での再接続試行回数。上限に達したら確定済み分だけで finalize する。
    private var sessionRetryCount = 0
    private static let maxSessionRetries = 3
    /// 録音の世代。startCapture ごとに進め、Esc キャンセルでも進める。バックオフ待ち中の
    /// リトライタスクが、キャンセル後に始まった別の録音のセッションを畳んだり
    /// 置き換えたりしないよう、要所で自分の世代がまだ現行かを確認するのに使う。
    /// エンジンの publish 直前チェック（validIf、エンジンのロック下で任意スレッドから
    /// 呼ばれる）でも読むため、MainActor 隔離の stored property ではなく
    /// スレッドセーフな箱に持つ。
    private let recordingGeneration = GenerationCounter()
    /// finalize 開始後にセッション中断が検知されたときの確定分の退避。
    /// finishAndTranscript が成功すれば同じテキストが返るため使わず、
    /// 失敗したときだけ救済に使う（carried へ直接足すと成功時に二重になる）。
    private var interruptedDuringFinalize: String?
    /// 現行セッションの確定分を既に carriedTranscript へ取り込み済みかどうか。
    /// true のとき finalize すると同じテキストが二重に返り得るため、
    /// stopAndFinalize はセッションを捨てて carried だけで確定する。
    private var sessionAlreadyCarried = false

    private let historyLogger = HistoryLogger(directory: RecordingController.appSupportDir)

    /// 参考音声モード（F11）の進行中セッション。録音中〜保存までの間だけ non-nil。
    /// 音声は ReferenceAudioWriter が入力レートのまま 24bit WAV に書く（音声認識とは並行・独立）。
    private var referenceWriter: ReferenceAudioWriter?
    private var referenceStartedAt: Date?
    private var referenceDeviceName: String?
    /// 書き起こしが返らないときに保存を待たせる上限。超えたら書き起こしなしで保存する。
    private static let referenceTranscribeTimeout: Duration = .seconds(15)

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
        Timing.mark("startup: begin")

        // プリセットのマイグレーションを確定させる（旧カスタム指示の取り込み等）。
        let store = loadPresetStore()
        try? store.save(to: Self.presetsURL)
        settings.selectedPresetID = store.selectedID.uuidString

        Timing.mark("startup: presets loaded")

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
            refinedKeyCode: settings.refinedHotkeyCode,
            referenceKeyCode: settings.referenceHotkeyCode))
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
        Timing.mark("startup: hotkey tap ready ★ここからF9が効く")
        // AVAudioEngine の inputNode 初回アクセスは HAL / オーディオデバイスの初期化を伴い
        // 数百ms（Bluetooth や外部IFではさらに）かかる。初回ホットキーで払わないよう前倒しする。
        // 未許可の状態で触ると TCC プロンプトが不意に出るため、許可済みのときだけ。
        recorder.setPreferredInputDevice(uid: settings.inputDeviceUID)
        engine.setContextualStrings(settings.recognitionHints)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            recorder.prewarm()
        }
        // デフォルト入力デバイスの常時監視。engine 完全停止中のアイドル時にデバイスが替わると、
        // engine が古いデバイス構成を抱えたまま次の start() 直後に構成変更が飛び、
        // アイドル明けの初回録音がキャンセルされる事故が起きていた（2026-09-04 調査）。
        // アイドル中に検知したら engine を畳んで prewarm() し直し、次回はクリーンに始める。
        // 録音中の変更は onDeviceChange（AVAudioEngineConfigurationChange）側で継続処理する。
        recorder.onDefaultInputDeviceChange = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                KoeLog.info("入力デバイス構成の変更（アイドル中）: 使用予定=\(self.recorder.inputDeviceName ?? "不明")")
                self.keepAliveTask?.cancel()
                self.keepAliveTask = nil
                // stop() だけだと engine が旧デバイスのフォーマットを抱えたままになり、
                // 次の installTap がサンプルレート不一致の例外で落ちるため作り直す。
                self.recorder.reset()
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    self.recorder.prewarm()
                }
            }
        }
        recorder.startObservingDefaultInputDevice()
        Timing.mark("startup: audio input node ready")
        // 初回 show() の NSPanel / NSHostingView 生成コスト（実測30-45ms）を前倒しする。
        hud.prewarm()
        Timing.mark("startup: HUD panel ready")
        reloadLastReferenceRecording()

        // モデル準備（失敗は通知のみ。自動リトライはせず、メニューの
        // 「音声モデルを再ダウンロード」から retryModelDownload() で手動再試行する）
        do {
            try await engine.prepare()
            // 準備できたら予熱まで済ませる（prepare はアセットの確認・DL だけで、
            // SpeechAnalyzer は作らないため、これが無いと初回 F9 でモデルロードを丸ごと払う）
            Timing.mark("startup: speech assets prepared")
            await engine.warmUp()
            Timing.mark("startup: speech warm-up done")
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

    /// 設定画面から入力マイクを変更する（nil = システムのデフォルト入力に従う）。
    /// 録音中なら次の録音から反映する。
    func setInputDevice(uid: String?) {
        settings.inputDeviceUID = uid
        recorder.setPreferredInputDevice(uid: uid)
        preferredDeviceMissingNotified = false
        KoeLog.info("入力マイク設定: \(uid ?? "システムのデフォルト")")
        if !isRecording, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            recorder.prewarm()
        }
    }

    /// 設定画面から認識ヒント語を変更する。次の録音から反映する。
    func setRecognitionHints(_ words: [String]) {
        settings.recognitionHints = words
        engine.setContextualStrings(words)
    }

    func reloadHotkeys() {
        monitor?.config = .init(
            rawKeyCode: settings.rawHotkeyCode,
            refinedKeyCode: settings.refinedHotkeyCode,
            referenceKeyCode: settings.referenceHotkeyCode)
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

        // 実際に録音へ使われる入力デバイス（システムデフォルト入力）を可視化する。
        // イヤホンを挿しただけで Studio Display マイク → 3.5mm ジャックの「外部マイク」へ
        // 静かに切り替わり、認識精度が落ちる事故が起きたため（2026-09-04 調査）、
        // HUD に常時表示し、前回セッションからデバイスが変わったときは一度だけ通知する。
        if effectiveRefine { RefinementService.preconnect() }

        if recorder.isPreferredDeviceMissing {
            if !preferredDeviceMissingNotified {
                notify("設定で固定したマイクが見つからないため、システムのデフォルト入力で録音します。接続を確認してください")
                preferredDeviceMissingNotified = true
            }
        } else {
            preferredDeviceMissingNotified = false
        }
        let deviceName = recorder.inputDeviceName
        if let deviceName {
            let key = "lastInputDeviceName"
            let last = UserDefaults.standard.string(forKey: key)
            if let last, last != deviceName {
                notify("入力マイクが「\(last)」から「\(deviceName)」に変わりました。認識精度に影響する場合があります")
            }
            UserDefaults.standard.set(deviceName, forKey: key)
        }
        hud.show(mode: mode == .reference ? .reference : (effectiveRefine ? .refined : .raw), deviceName: deviceName)
        KoeLog.info("録音開始: mode=\(mode.rawValue) refine=\(effectiveRefine) device=\(deviceName ?? "不明")")

        // 参考音声モード: 音声認識と並行して、入力レートのまま WAV 用に書き溜める。
        // onBuffer を張る前に用意し、キープアライブ中の即時再開でも頭を落とさない。
        var writer: ReferenceAudioWriter?
        if mode == .reference {
            let w = ReferenceAudioWriter()
            do {
                try w.start()
            } catch {
                KoeLog.error("参考音声: 一時ファイルを作れません: \(error.localizedDescription)")
                notify("参考音声を開始できませんでした: \(error.localizedDescription)")
                dispatch(.failure)
                return
            }
            writer = w
            referenceWriter = w
            referenceStartedAt = Date()
            referenceDeviceName = deviceName
        }

        // AudioRecorder のコールバックは @Sendable（オーディオスレッドから呼ばれるため）。
        // MainActor 隔離クラスの stored property を @Sendable クロージャ内で直接読むことは
        // できないため、事前にローカルへ退避してからキャプチャする。
        let engine = self.engine

        // マイクは音声認識セッションの準備完了を待たずに先に開ける。
        // startSession() は analyzer.start()（音声モデルのロード）を含み、コールドスタートでは
        // 数百ms〜数秒かかる。これを待ってから録音を始めると、HUD が出ている間の発話が
        // 丸ごと失われて「認識が遅い」体感になるため、公開までの音声は engine 側に待避させ、
        // セッション公開時に順序どおり流し込む。
        // beginBuffering は待避中なら既存バッファを保持する仕様のため、新規録音では
        // 前回の残骸（再接続リトライが中断されたケース）を必ず先に捨てる。
        engine.discardBuffered()
        engine.beginBuffering()
        let micFormat = recorder.inputFormat
        engine.configureMicFormat(micFormat)
        // @Sendable を明記する（MainActor 隔離コンテキストからの代入で MainActor 推論が
        // 効くと、オーディオスレッド実行時に dispatch_assert_queue_fail でクラッシュする。
        // docs/spike-results.md スパイクB 参照）。
        if let writer {
            recorder.onBuffer = { @Sendable buffer in
                engine.feed(buffer)
                writer.append(buffer)
            }
        } else {
            recorder.onBuffer = { @Sendable buffer in
                engine.feed(buffer)
            }
        }
        recorder.onLevel = { @Sendable [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
                self?.hud.updateLevel(level)
            }
        }
        recorder.onDeviceChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // キープアライブ中（録音していない）のデバイス変更は、次の start() で
                // 新しいデバイスを掴み直せるようエンジンを畳むだけにする。
                guard self.isRecording else {
                    self.keepAliveTask?.cancel()
                    self.keepAliveTask = nil
                    self.recorder.reset()
                    return
                }
                self.restartRecorderForDeviceChange()
            }
        }
        deviceRestartTask?.cancel()
        deviceRestartTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        do {
            let actual = try recorder.start()
            // engine を作り直した場合は事前に読んだフォーマットと変わり得る。
            // バッファは start() 後にしか届かないため、ここで合わせれば変換は崩れない。
            if actual != micFormat { engine.configureMicFormat(actual) }
            KoeLog.info("マイク開始: \(Int(actual.sampleRate))Hz \(actual.channelCount)ch")
        } catch {
            engine.discardBuffered()
            referenceWriter?.discard()
            referenceWriter = nil
            KoeLog.error("録音開始に失敗: \(error.localizedDescription)")
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
        carriedTranscript = ""
        interruptedDuringFinalize = nil
        sessionAlreadyCarried = false
        sessionRetryCount = 0
        let generation = recordingGeneration.bump()
        // 前の録音のセッション開始／リトライがまだ走っていれば完了を待ってから始める。
        // engine.startSession() を並走させると publish が競合し、古いタスクが新しい
        // セッションを畳む事故が起きるため、セッション開始は必ず直列にする。
        let previous = sessionStart
        let counter = recordingGeneration
        let start = Task { () -> AsyncStream<TranscriptUpdate> in
            _ = try? await previous?.value
            // startSession の await 中に世代が替わったら公開直前で破棄させる
            // （失効したセッションが待避バッファを流し込んで消すのを防ぐ）。
            return try await engine.startSession(validIf: { counter.current() == generation })
        }
        sessionStart = start
        attachSession(start, isInitial: true, generation: generation)
    }

    /// セッションの updates を購読して HUD へ流す。録音中にセッションが異常終了
    /// （メモリ枯渇による認識デーモン消滅など。2026-09-09 調査）したら、確定済み
    /// テキストを引き継いで新しいセッションへ再接続する。
    private func attachSession(
        _ start: Task<AsyncStream<TranscriptUpdate>, Error>,
        isInitial: Bool, generation: Int
    ) {
        Task {
            do {
                let updates = try await start.value
                // キャンセル後も stream が finish するまで最大1回 stale な partial が届き得るが、
                // engine 側のセッション guard（currentSession() 比較）により後続セッションの
                // 結果に紛れ込むことはなく実害なし。
                for await update in updates {
                    if update.sessionInterrupted {
                        handleSessionInterrupted(
                            finalizedText: update.displayText, generation: generation)
                        continue  // この更新を最後に stream は finish する
                    }
                    let display = carriedTranscript + update.displayText
                    partialText = display
                    hud.updateText(display)
                }
            } catch {
                // 世代失効による自主破棄（publish 拒否・リトライガード）。エラーではない。
                if error is CancellationError { return }
                if isInitial {
                    notify("音声認識を開始できませんでした: \(error.localizedDescription)")
                    // finalize 中（開始完了前に停止された）は failure を流さない。
                    // 流すと idle へ遷移して cancelSession が待避音声ごと破棄し、
                    // stopAndFinalize の再開始による救済経路を壊すため、
                    // 失敗の裁定は stopAndFinalize に委ねる。
                    // 参考音声モードでは認識が無くても WAV は残すので録音を続ける
                    // （停止時に書き起こし空のまま保存する）。
                    if isRecording, currentMode != .reference { dispatch(.failure) }
                } else {
                    // 再接続の試行自体が失敗。上限まで次の試行へ回す
                    // （世代が古い場合は handleSessionInterrupted 側で握りつぶされる）。
                    handleSessionInterrupted(finalizedText: "", generation: generation)
                }
            }
        }
    }

    private func handleSessionInterrupted(finalizedText: String, generation: Int) {
        KoeLog.error("音声認識セッション中断: retry=\(sessionRetryCount) recording=\(isRecording)")
        // 別の録音が始まった後に起きた古い世代の中断は一切触らない
        // （carried への追記も、新しい録音のテキストを汚すため行わない）。
        guard generation == recordingGeneration.current() else { return }
        guard isRecording else {
            // finalize 開始後の中断: carried へ直接足すと finishAndTranscript が
            // 成功したとき同じテキストが二重になるため、失敗時の救済用に退避だけする。
            // 空文字（リトライ開始自体の失敗）で先に退避した確定分を潰さない。
            if !finalizedText.isEmpty { interruptedDuringFinalize = finalizedText }
            return
        }
        carriedTranscript += finalizedText
        guard sessionRetryCount < Self.maxSessionRetries else {
            notify("音声認識との接続が回復できませんでした。ここまでの内容で確定します")
            // 現行セッションの確定分は carried に取り込み済み。finalize が万一
            // 成功すると同じテキストが二重に返るため、stopAndFinalize には
            // finalize せず carried だけで確定させる。
            sessionAlreadyCarried = true
            dispatch(.maxDurationReached)  // 通常の finalize 経路で確定済み分を救済
            return
        }
        sessionRetryCount += 1
        if sessionRetryCount == 1 {
            notify("音声認識が中断されました。再接続しています…")
        }
        let attempt = sessionRetryCount
        let engine = self.engine
        let counter = recordingGeneration
        let start = Task { () -> AsyncStream<TranscriptUpdate> in
            // 停止（finalize 中）でも降りずに続行する: 待避した音声を新セッションで
            // 確定させるため。降りるのは Esc・別録音開始で世代が替わったときだけ。
            guard counter.current() == generation,
                  self.isRecording || self.isFinalizing else {
                throw CancellationError()
            }
            // 待避を先に開始してから死んだセッションを畳む。cancelSession は同期的に
            // inputBuilder を外すため、以降の feed() は待避バッファへ回る。この順序を
            // 逆にすると、cancel の await 中（teardown が遅いことがある）に届いた
            // 音声が inputBuilder も待避も無い隙間に落ちて消える。
            // beginBuffering は待避中なら既存バッファを保持するため、
            // 失敗した前の試行が待避した分も残る。
            engine.beginBuffering()
            engine.configureMicFormat(self.recorder.inputFormat)
            await engine.cancelSession()
            // デーモンの再起動を待つバックオフ（0.5s/1s/2s）。
            try? await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 1))))
            guard counter.current() == generation,
                  self.isRecording || self.isFinalizing else {
                throw CancellationError()
            }
            // 世代の再検証はエンジンが publish 直前（ロック下）に行う。await 中に
            // 世代が替わった場合はセッションが公開されず破棄されるため、失効した
            // リトライが新しい録音の待避バッファを流し込んで消すことはない。
            return try await engine.startSession(validIf: { counter.current() == generation })
        }
        sessionStart = start
        attachSession(start, isInitial: false, generation: generation)
    }

    private func stopAndFinalize() {
        if currentMode == .reference {
            stopAndFinalizeReference()
            return
        }
        KoeLog.info("録音停止→確定処理")
        isRecording = false
        isFinalizing = true
        hud.showFinalizing()
        maxDurationTask?.cancel()
        pauseMicWithKeepAlive()
        let start = sessionStart
        Task {
            // セッション公開前に停止された場合（モデルロード中の短い発話）に備え、開始完了を
            // 待ってから finalize する。待たずに finishAndTranscript すると notStarted となり、
            // 待避しておいた音声ごと失われる。
            var restartedForFinalize = false
            if let start, (try? await start.value) == nil {
                // 開始（または再接続）が失敗したまま停止された。待避音声が残っている
                // 可能性があるため、確定のために開始をもう一度だけ試す（成功すれば
                // 待避分が新セッションへ流れ込み、直後の finalize で確定する）。
                // それも駄目で、引き継ぎ済みの確定分も無ければ失敗として畳む。
                if (try? await engine.startSession()) != nil {
                    restartedForFinalize = true
                } else if carriedTranscript.isEmpty {
                    dispatch(.failure)  // 通知は attachSession 側で出している
                    return
                }
            }
            var text = ""
            if sessionAlreadyCarried && !restartedForFinalize {
                // 現行セッションの確定分は既に carried へ取り込み済み（再接続を
                // 諦めたケース）。finalize すると同じテキストが二重に返り得るため、
                // セッションは捨てるだけにする。再開始に成功した場合は別で、
                // その新セッションには待避音声だけが入っており carried と重複
                // しないため、通常どおり finalize して取り込む。
                await engine.cancelSession()
            } else {
                do {
                    text = try await engine.finishAndTranscript()
                } catch {
                    // セッション異常終了後の finalize は失敗し得る。中断検知が退避した
                    // 確定分・引き継ぎ済みの carried があればそれで続行し、
                    // 何も無ければ従来どおり失敗として畳む。
                    text = interruptedDuringFinalize ?? ""
                    guard !(carriedTranscript + text).isEmpty else {
                        notify("認識に失敗しました: \(error.localizedDescription)")
                        dispatch(.failure)
                        return
                    }
                }
            }
            let full = (carriedTranscript + text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replaced = ReplacementDictionary.load(from: Self.replacementsURL).apply(to: full)
            if replaced.isEmpty {
                dispatch(.failure)  // 空結果 → 静かにキャンセル
            } else {
                pendingTranscript = replaced
                dispatch(.transcriptReady(refine: sessionRefine))
            }
        }
    }

    private func cancelSession() {
        KoeLog.info("録音キャンセル")
        isRecording = false
        isFinalizing = false
        maxDurationTask?.cancel()
        pauseMicWithKeepAlive()
        hud.hide()
        engine.discardBuffered()
        referenceWriter?.discard()
        referenceWriter = nil
        carriedTranscript = ""
        interruptedDuringFinalize = nil
        sessionAlreadyCarried = false
        sessionRetryCount = 0
        // 世代を進め、バックオフ待ち中のリトライタスクを無効化する。
        let generation = recordingGeneration.bump()
        let start = sessionStart
        // sessionStart はここで nil にしない。開始途中のタスクをチェーンに残しておくことで、
        // 直後に始まる次の録音が previous として完了を待ち、startSession() の並走
        // （publish の競合で新録音のセッションが古いタスクに畳まれる事故）を防ぐ。
        Task {
            // 開始途中なら公開まで待ってからキャンセルする。待たずに cancel すると、
            // 直後に公開されたセッションが誰にも止められないまま走り続ける。
            _ = try? await start?.value
            // 待っている間に別の録音が始まっていたら、そのセッションを
            // 巻き込んで畳まないよう手を引く。
            guard self.recordingGeneration.current() == generation else { return }
            await engine.cancelSession()
        }
    }

    /// 録音中にオーディオ構成が変わったとき、録音をキャンセルせずエンジンを組み直して続行する
    /// （AVAudioEngineConfigurationChange への Apple 推奨対応）。組み直しの間の音声
    /// （数百ms）は欠けるが、それまでの認識セッションと確定済みテキストはそのまま生きる。
    private func restartRecorderForDeviceChange() {
        deviceRestartTask?.cancel()
        deviceRestartTask = Task { [weak self] in
            // 切替時は通知が連続するため、少し待って1回の再起動に合流させる
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            if self.currentMode == .reference {
                // 参考音声はリサンプリングしない方針なので、レートが変わり得るデバイス切替を
                // またいで1ファイルにはしない。ここまでの音声で保存して終える。
                KoeLog.info("参考音声: 録音中の入力構成変更→ここまでで保存")
                self.notify("入力マイクが変わったため、参考音声はここまでで保存します")
                self.dispatch(.maxDurationReached)
                return
            }
            KoeLog.info("録音中の入力構成変更→レコーダー再起動: \(self.recorder.inputDeviceName ?? "不明")")
            // 新しいデバイスのフォーマットを確実に掴むため engine ごと作り直す。
            self.recorder.reset()
            let micFormat = self.recorder.inputFormat
            self.engine.configureMicFormat(micFormat)
            do {
                let actual = try self.recorder.start()
                if actual != micFormat { self.engine.configureMicFormat(actual) }
                if let deviceName = self.recorder.inputDeviceName {
                    let key = "lastInputDeviceName"
                    if UserDefaults.standard.string(forKey: key) != deviceName {
                        self.notify("入力マイクが「\(deviceName)」に変わりました。録音は継続しています")
                        UserDefaults.standard.set(deviceName, forKey: key)
                    }
                    self.hud.updateDeviceName(deviceName)
                }
            } catch {
                self.notify("入力デバイスの切り替え後に録音を再開できませんでした: \(error.localizedDescription)")
                self.dispatch(.failure)
            }
        }
    }

    /// 録音を止めるが、AVAudioEngine は猶予時間だけ回したままにする。
    /// 猶予内に次の録音が始まればデバイス起動待ちゼロ、来なければ完全停止して
    /// マイクインジケータを消す。
    private func pauseMicWithKeepAlive() {
        recorder.pause()
        deviceRestartTask?.cancel()
        deviceRestartTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.micKeepAlive)
            guard !Task.isCancelled, let self else { return }
            self.recorder.stop()
            // 完全停止後も、次回の start() が速いようにリソースだけ確保し直しておく
            // （IO は開始しないのでマイクインジケータは消灯したまま）。
            self.recorder.prewarm()
            self.keepAliveTask = nil
        }
    }

    private func beginRefining() {
        hud.showRefining()
        let instruction = loadPresetStore().selected.instruction
        let modelID = settings.modelID
        let glossary = settings.recognitionHints
        let inputLength = pendingTranscript.count
        Task {
            let began = ContinuousClock.now
            let (text, fallbackReason) = await refinement.refine(
                pendingTranscript, modelID: modelID, instruction: instruction, glossary: glossary)
            let elapsed = ContinuousClock.now - began
            KoeLog.info("AI整形: \(fallbackReason.map { "fallback=\($0)" } ?? "ok") "
                + "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)ms "
                + "chars=\(inputLength)→\(text.count)")
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
        if currentMode == .reference {
            deliverReferencePath(text)
            return
        }
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

    // MARK: - 参考音声モード（F11）

    /// 参考音声の停止: 書き起こし（失敗・空でも続行）→ WAV 仕上げ → サイドカー JSON → パスの受け渡しへ。
    /// 通常モードの置換辞書・履歴・直近3件は一切通さない。
    private func stopAndFinalizeReference() {
        KoeLog.info("参考音声: 録音停止→保存処理")
        isRecording = false
        isFinalizing = true
        hud.showFinalizing()
        maxDurationTask?.cancel()
        pauseMicWithKeepAlive()
        let start = sessionStart
        let writer = referenceWriter
        referenceWriter = nil
        let startedAt = referenceStartedAt ?? Date()
        let deviceName = referenceDeviceName ?? "不明"
        let engine = self.engine
        let trimmer: SilenceTrimmer? = settings.referenceTrimSilence ? SilenceTrimmer() : nil
        let directory = settings.referenceRecordingsDirectory
        Task {
            let began = ContinuousClock.now
            // 書き起こし。セッション開始待ち＋確定をまとめて上限時間で打ち切り、
            // 超えたらそれまでの確定分（carried）だけで進む（WAV の保存は認識に依存させない）。
            // セッションが開始できていなければ書き起こしは空。
            // 再接続を諦めたセッション（確定分は carried に取り込み済み）を finalize すると
            // 同じテキストが二重に返り得るため、通常モードと同じく finalize せず捨てる。
            let alreadyCarried = sessionAlreadyCarried
            let transcript: String? = await Self.race({
                guard let start, (try? await start.value) != nil, !alreadyCarried else { return "" }
                return (try? await engine.finishAndTranscript()) ?? ""
            }, {
                try? await Task.sleep(for: Self.referenceTranscribeTimeout)
                return nil
            })
            if transcript == nil {
                KoeLog.error("参考音声: 書き起こしが時間内に確定せず、書き起こしなしで保存する")
                // 開始途中のセッションが後から公開されないよう世代を進め、公開済みなら畳む。
                _ = recordingGeneration.bump()
            }
            await engine.cancelSession()
            engine.discardBuffered()
            let text = (carriedTranscript + (transcript ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            carriedTranscript = ""
            let transcribeMs = Self.milliseconds(since: began)

            guard let writer else {
                KoeLog.error("参考音声: ライターが無い（開始に失敗していた）")
                dispatch(.failure)
                return
            }
            let base = ReferenceRecordingNaming.uniqueBaseName(
                ReferenceRecordingNaming.baseName(date: startedAt, transcript: text)
            ) { candidate in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(candidate).appendingPathExtension("wav").path)
            }
            let wavURL = directory.appendingPathComponent(base).appendingPathExtension("wav")
            do {
                // 一時ファイル→WAV のコピーはメインを止めないよう別スレッドで行う
                let result = try await Task.detached(priority: .userInitiated) {
                    try writer.finish(to: wavURL, trim: trimmer)
                }.value
                let sidecar = ReferenceSidecar(
                    text: text, sampleRate: Int(result.sampleRate.rounded()),
                    durationSec: result.durationSec, device: deviceName, recordedAt: startedAt)
                do {
                    try sidecar.write(to: ReferenceSidecar.url(for: wavURL))
                } catch {
                    KoeLog.error("参考音声: サイドカーの書き込みに失敗: \(error.localizedDescription)")
                }
                KoeLog.info(
                    "参考音声: 保存 file=\(Self.referenceLogID(wavURL)) rate=\(Int(result.sampleRate))Hz "
                    + "duration=\(String(format: "%.2f", result.rawDurationSec))s→\(String(format: "%.2f", result.durationSec))s "
                    + "transcribe=\(transcribeMs)ms total=\(Self.milliseconds(since: began))ms "
                    + "textChars=\(text.count)")
                if text.isEmpty {
                    notify("参考音声を保存しました（書き起こしは空です）")
                }
                lastReferenceRecording = ReferenceRecordingInfo(
                    url: wavURL, durationSec: result.durationSec, text: text)
                settings.lastReferenceRecordingPath = wavURL.path
                pendingTranscript = wavURL.path
                dispatch(.transcriptReady(refine: false))
            } catch {
                writer.discard()
                KoeLog.error("参考音声: 保存に失敗: \(error.localizedDescription)")
                notify("参考音声を保存できませんでした: \(error.localizedDescription)")
                dispatch(.failure)
            }
        }
    }

    /// 保存した WAV の絶対パスを設定どおりに受け渡す（入力欄へ挿入 or クリップボードのみ）。
    private func deliverReferencePath(_ path: String) {
        isFinalizing = false
        let delivery = settings.referenceDelivery
        Task {
            switch delivery {
            case .insert:
                let posted = await inserter.insert(path)
                if !posted {
                    notify("パスを挿入できませんでした。クリップボードにあります")
                }
            case .clipboardOnly:
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(path, forType: .string)
                notify("参考音声のパスをクリップボードにコピーしました")
            }
            hud.hide()
            dispatch(.insertionFinished)
        }
    }

    /// 2つの非同期処理を競わせ、先に終わった方の値を返す。負けた側は止めない
    /// （withTaskGroup はスコープを抜けるときに全子タスクの完了を待つため、キャンセルに
    /// 応じない処理——analyzer の finalize 待ちなど——を抱えると期限が効かない）。
    /// 負けた側は背景で完走して結果が捨てられる。
    private static func race<T: Sendable>(
        _ a: @escaping @Sendable () async -> T,
        _ b: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(await a()) }
            Task { once.resume(await b()) }
        }
    }

    private static func milliseconds(since began: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - began
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// 設定に残した直前の参考音声を読み直す（起動時・削除後）。ファイルが無ければ nil。
    func reloadLastReferenceRecording() {
        guard let path = settings.lastReferenceRecordingPath else {
            lastReferenceRecording = nil
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastReferenceRecording = nil
            settings.lastReferenceRecordingPath = nil
            return
        }
        let sidecar = try? ReferenceSidecar.load(from: ReferenceSidecar.url(for: url))
        lastReferenceRecording = ReferenceRecordingInfo(
            url: url, durationSec: sidecar?.durationSec ?? 0, text: sidecar?.text ?? "")
    }

    /// 直前の参考音声を WAV・サイドカーごと削除する。
    /// ログ用の識別子。ファイル名には書き起こしの先頭が入るため、日時部分（yyyyMMdd-HHmmss）だけを残す。
    private static func referenceLogID(_ url: URL) -> String {
        String(url.deletingPathExtension().lastPathComponent.prefix(15))
    }

    func deleteLastReferenceRecording() {
        guard let info = lastReferenceRecording else { return }
        try? FileManager.default.removeItem(at: info.url)
        try? FileManager.default.removeItem(at: ReferenceSidecar.url(for: info.url))
        KoeLog.info("参考音声: 削除 file=\(Self.referenceLogID(info.url))")
        settings.lastReferenceRecordingPath = nil
        lastReferenceRecording = nil
    }

    private func notify(_ message: String) {
        KoeLog.info("通知: \(message)")
        let content = UNMutableNotificationContent()
        content.title = "Koe"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// continuation を一度だけ再開する箱（race 用）。
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// ポップオーバーに出す「直前の参考音声」。
struct ReferenceRecordingInfo: Equatable, Sendable {
    let url: URL
    let durationSec: Double
    let text: String
}

/// 録音の世代カウンタ。MainActor（コントローラの各種ガード）からも、エンジンの
/// publish 直前チェック（validIf、エンジンのロック下で任意スレッドから呼ばれる）
/// からも読むため、MainActor 隔離の stored property ではなくロックで守る。
final class GenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    func current() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 開発用: 起動〜録音開始の各フェーズ所要時間を計測する（`KoeApp --input-smoke`）。
/// 「F9 を押してから実際に音が録れ始めるまで」の内訳を数値で切り分けるためのもので、
/// 通常動作では一切呼ばれない。private メンバへ触るため同一ファイルの extension に置く。
extension RecordingController {
    /// オーディオスレッドから最初のバッファ到着時刻を記録する箱。
    final class FirstBufferClock: @unchecked Sendable {
        private let lock = NSLock()
        private var first: DispatchTime?
        private var frames: UInt32 = 0
        func mark(_ count: AVAudioFrameCount) {
            lock.lock(); defer { lock.unlock() }
            if first == nil { first = DispatchTime.now() }
            frames += count
        }
        func elapsedMs(since t: DispatchTime) -> String {
            lock.lock(); defer { lock.unlock() }
            guard let first else { return "NEVER" }
            return String(format: "%.1fms", Double(first.uptimeNanoseconds - t.uptimeNanoseconds) / 1e6)
        }
        var totalFrames: UInt32 {
            lock.lock(); defer { lock.unlock() }
            return frames
        }
    }

    private static func ms(since t: DispatchTime) -> String {
        String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6)
    }

    /// stdout はパイプ接続時にブロックバッファリングされ、途中経過が見えない。
    /// 計測ログは stderr へ即時書き出す。
    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    func measureStartLatency(label: String) async {
        let t0 = DispatchTime.now()
        hud.show(mode: .raw)
        Self.log("[\(label)] HUD_SHOW           \(Self.ms(since: t0))")

        let t1 = DispatchTime.now()
        let format = recorder.inputFormat
        Self.log("[\(label)] INPUT_FORMAT       \(Self.ms(since: t1))  \(format.sampleRate)Hz \(format.channelCount)ch")

        engine.beginBuffering()
        let t2 = DispatchTime.now()
        engine.configureMicFormat(format)
        Self.log("[\(label)] CONFIGURE_FORMAT   \(Self.ms(since: t2))")

        let clock = FirstBufferClock()
        recorder.onBuffer = { @Sendable buffer in clock.mark(buffer.frameLength) }
        recorder.onLevel = nil
        recorder.onDeviceChange = nil

        let t3 = DispatchTime.now()
        do { try recorder.start() } catch {
            Self.log("[\(label)] RECORDER_START     FAILED \(error)")
            engine.discardBuffered()
            return
        }
        Self.log("[\(label)] RECORDER_START     \(Self.ms(since: t3))")

        let t4 = DispatchTime.now()
        let started = try? await engine.startSession()
        Self.log("[\(label)] SESSION_START      \(Self.ms(since: t4))  \(started == nil ? "FAILED" : "ok")")

        // 実際に音が録れ始めるまで（= 発話の頭が欠ける長さ）。start() 呼び出しからの経過。
        try? await Task.sleep(for: .seconds(2))
        Self.log("[\(label)] FIRST_BUFFER       \(clock.elapsedMs(since: t3))  frames=\(clock.totalFrames)")
        Self.log("[\(label)] TOTAL_HOTKEY_TO_MIC \(clock.elapsedMs(since: t0))")

        // 本番と同じ経路で止める（キープアライブが効くかどうかも計測対象にする）
        pauseMicWithKeepAlive()
        recorder.onBuffer = nil
        await engine.cancelSession()
        engine.discardBuffered()
        hud.hide()
        Self.log("[\(label)] mic_kept_alive=\(recorder.isKeptAlive)")
    }
}
