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

    func startSession() async throws -> AsyncStream<TranscriptUpdate> {
        let session = UUID()
        setSessionID(session)

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

        storeSessionState(analyzer: analyzer, transcriber: transcriber, builder: builder, format: format)

        try await analyzer.start(inputSequence: inputSequence)

        let (updates, updateCont) = AsyncStream<TranscriptUpdate>.makeStream()
        resultsTask = Task { [weak self] in
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
    private func takeBuilderAndAnalyzerForFinish() -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) {
        lock.lock(); defer { lock.unlock() }
        let builder = inputBuilder
        let analyzer = self.analyzer
        inputBuilder = nil
        return (builder, analyzer)
    }

    private func takeBuilderAndAnalyzerForCancel() -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) {
        lock.lock(); defer { lock.unlock() }
        let builder = inputBuilder
        let analyzer = self.analyzer
        inputBuilder = nil
        sessionID = UUID()  // 遅延結果を無効化
        return (builder, analyzer)
    }

    func finishAndTranscript() async throws -> String {
        let (builder, analyzer) = takeBuilderAndAnalyzerForFinish()
        guard let builder, let analyzer else { throw EngineError.notStarted }
        builder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = await resultsTask?.value ?? ""
        teardown()
        return text
    }

    func cancelSession() async {
        let (builder, analyzer) = takeBuilderAndAnalyzerForCancel()
        builder?.finish()
        resultsTask?.cancel()
        try? await analyzer?.cancelAndFinishNow()
        teardown()
    }

    private func teardown() {
        lock.lock(); defer { lock.unlock() }
        analyzer = nil
        transcriber = nil
        converter = nil
        resultsTask = nil
    }
}
