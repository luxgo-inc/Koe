import AVFoundation
import Speech

/// SpeechAnalyzer/SpeechTranscriber ベースの日本語オンデバイス認識。
/// volatile 結果は「置換」で統合する: 確定済み finalizedText に、最新の volatile を連結して表示する。
/// セッション ID で旧セッションの遅延結果を破棄する。
final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var micFormat: AVAudioFormat?
    private var resultsTask: Task<String, Never>?
    private var sessionID = UUID()
    private let lock = NSLock()

    enum EngineError: Error { case localeUnsupported, formatUnavailable, notStarted }

    /// finishAndTranscript()/cancelSession() が同一セッションのリソースを一度だけ
    /// クレームできるようにするための束。1回のロック取得で全て nil 化して返す。
    private struct ClaimedResources {
        let builder: AsyncStream<AnalyzerInput>.Continuation?
        let analyzer: SpeechAnalyzer?
        let resultsTask: Task<String, Never>?
    }

    func prepare() async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "ja-JP")) else {
            throw EngineError.localeUnsupported
        }
        let probe = SpeechTranscriber(
            locale: supported, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    func configureMicFormat(_ format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        micFormat = format
    }

    private func setSessionID(_ session: UUID) {
        lock.lock(); defer { lock.unlock() }
        sessionID = session
    }

    private func storeSessionState(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        builder: AsyncStream<AnalyzerInput>.Continuation,
        format: AVAudioFormat
    ) {
        lock.lock(); defer { lock.unlock() }
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputBuilder = builder
        self.analysisFormat = format
        if let mic = micFormat { self.converter = AVAudioConverter(from: mic, to: format) }
    }

    private func setResultsTask(_ task: Task<String, Never>?) {
        lock.lock(); defer { lock.unlock() }
        resultsTask = task
    }

    func startSession() async throws -> AsyncStream<TranscriptUpdate> {
        // 前のセッションがまだ生きていれば、その資源を静かにリークさせず
        // cancelSession() 経路で先に破棄する（冪等: 何も無ければ no-op）。
        await cancelSession()

        guard let supported = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "ja-JP")) else {
            throw EngineError.localeUnsupported
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.formatUnavailable
        }
        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()

        // ロケール・フォーマット確定後に初めてセッションを「有効」にする。
        // 失敗した2回目の start が生きているセッションを巻き込んで潰さないようにするため。
        let session = UUID()
        setSessionID(session)
        storeSessionState(analyzer: analyzer, transcriber: transcriber, builder: builder, format: format)

        try await analyzer.start(inputSequence: inputSequence)

        let (updates, updateCont) = AsyncStream<TranscriptUpdate>.makeStream()
        let task = Task { [weak self] in
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    guard let self, self.currentSession() == session else { break }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        updateCont.yield(TranscriptUpdate(displayText: finalized))
                    } else {
                        updateCont.yield(TranscriptUpdate(displayText: finalized + text))
                    }
                }
            } catch {
                // finalize 時に届く正常終了エラーも含む。確定分だけ返す。
            }
            updateCont.finish()
            return finalized
        }
        setResultsTask(task)
        return updates
    }

    private func currentSession() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return sessionID
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let builder = inputBuilder, let format = analysisFormat, let converter else {
            lock.unlock(); return
        }
        lock.unlock()
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 {
            builder.yield(AnalyzerInput(buffer: out))
        }
    }

    /// NSLock.lock()/unlock() は async 関数の本体から直接呼べない
    /// （async-safe scoped locking を要求されるため）。同期メソッドに切り出して呼ぶ。
    /// 1回のロック取得で builder/analyzer/resultsTask を全てクレーム（nil化）して返すことで、
    /// finishAndTranscript() と cancelSession() が同じ SpeechAnalyzer を同時に
    /// 触ってしまう競合を防ぐ。newSessionID を渡すと同時に sessionID も更新する
    /// （cancelSession 用: 遅延結果を無効化）。
    private func claimSessionResources(newSessionID: UUID? = nil) -> ClaimedResources {
        lock.lock(); defer { lock.unlock() }
        let builder = inputBuilder
        let analyzer = self.analyzer
        let task = resultsTask
        inputBuilder = nil
        self.analyzer = nil
        resultsTask = nil
        if let newSessionID { sessionID = newSessionID }
        return ClaimedResources(builder: builder, analyzer: analyzer, resultsTask: task)
    }

    func finishAndTranscript() async throws -> String {
        let claimed = claimSessionResources()
        guard let builder = claimed.builder, let analyzer = claimed.analyzer else {
            throw EngineError.notStarted
        }
        do {
            builder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            claimed.resultsTask?.cancel()
            teardown()
            throw error
        }
        let text = await claimed.resultsTask?.value ?? ""
        teardown()
        return text
    }

    func cancelSession() async {
        let claimed = claimSessionResources(newSessionID: UUID())  // 遅延結果を無効化
        claimed.builder?.finish()
        claimed.resultsTask?.cancel()
        await claimed.analyzer?.cancelAndFinishNow()
        teardown()
    }

    private func teardown() {
        lock.lock(); defer { lock.unlock() }
        transcriber = nil
        converter = nil
    }
}
