import AVFoundation
import Speech

/// SpeechAnalyzer/SpeechTranscriber ベースの日本語オンデバイス認識。
/// volatile 結果は「置換」で統合する: 確定済み finalizedText に、最新の volatile を連結して表示する。
/// セッション ID で旧セッションの遅延結果を破棄する。
public final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public init() {}

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var micFormat: AVAudioFormat?
    private var resultsTask: Task<String, Never>?
    private var sessionID = UUID()
    private let lock = NSLock()

    /// セッション公開前に届いた音声の待避バッファ（録音頭の欠落防止）。
    /// beginBuffering() から publishSessionState()（または discardBuffered()）までの間だけ使う。
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0
    private var isBuffering = false
    /// 待避バッファの上限（秒）。モデルロードが異常に遅い場合でも青天井にしない。
    private static let maxBufferedSeconds: Double = 15

    public enum EngineError: Error { case localeUnsupported, formatUnavailable, notStarted }

    /// finishAndTranscript()/cancelSession() が同一セッションのリソースを一度だけ
    /// クレームできるようにするための束。1回のロック取得で全フィールドを nil 化して返す。
    /// 5フィールド全て（inputBuilder/analyzer/resultsTask/transcriber/converter）を
    /// ここに含めることで、あるセッションの遅い finishAndTranscript（finalize 待ち）が
    /// 後発セッションが既に格納した新しい transcriber/converter を巻き込んで消す、
    /// という競合を防ぐ。クレーム後は呼び出し元のローカル変数がオーナーになり、
    /// スコープを抜ければ自然に解放されるため、別途 teardown() は不要。
    private struct ClaimedResources {
        let builder: AsyncStream<AnalyzerInput>.Continuation?
        let analyzer: SpeechAnalyzer?
        let resultsTask: Task<String, Never>?
        let transcriber: SpeechTranscriber?
        let converter: AVAudioConverter?
    }

    public func prepare() async throws {
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

    /// startSession() の完了を待たずにマイクを開けるようにする。呼んだ時点から
    /// セッション公開までの feed() は捨てずに待避され、公開時に順序どおり流し込まれる。
    /// 録音開始（AudioRecorder.start）より前に呼ぶこと。
    public func beginBuffering() {
        lock.lock(); defer { lock.unlock() }
        pendingBuffers.removeAll()
        pendingFrames = 0
        isBuffering = true
    }

    /// 待避バッファを破棄する（開始失敗・キャンセル時）。
    /// 注意: claimSessionResources() では触らない。startSession() は先頭で cancelSession() を
    /// 呼ぶため、そこで待避状態を落とすと beginBuffering() 直後の録音頭が失われる。
    public func discardBuffered() {
        lock.lock(); defer { lock.unlock() }
        pendingBuffers.removeAll()
        pendingFrames = 0
        isBuffering = false
    }

    public func configureMicFormat(_ format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        micFormat = format
        // 原則は startSession() より前に呼ぶこと（公開時に converter が作られる）。
        // 万一セッション公開後に呼ばれても入力が無音で捨てられ続けないよう、
        // 公開済みの analysisFormat があれば converter をここで作り直す。
        if let analysisFormat {
            converter = AVAudioConverter(from: format, to: analysisFormat)
        }
    }

    /// analyzer.start() 成功後にのみ呼ぶ。セッション ID とセッション資源（resultsTask を含む
    /// 6項目全て）を1回のロック取得でまとめて「公開」する。公開前に外部から cancelSession() /
    /// finishAndTranscript() が割り込んでも、start() 完了前の analyzer を掴んでしまうことがなく、
    /// また「4項目は公開済みだが resultsTask だけ nil」という中間状態も存在しない
    /// （resultsTask を別ロックで後追い設定すると、その隙間で cancel が resultsTask=nil を
    /// クレームし、直後の後追い設定が「もう誰にも所有されていない」古い task を self に
    /// 書き戻してしまう競合が起きるため、必ず同一ロックで公開する）。
    private func publishSessionState(
        session: UUID,
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        builder: AsyncStream<AnalyzerInput>.Continuation,
        format: AVAudioFormat,
        resultsTask: Task<String, Never>
    ) {
        lock.lock(); defer { lock.unlock() }
        sessionID = session
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputBuilder = builder
        self.analysisFormat = format
        if let mic = micFormat { self.converter = AVAudioConverter(from: mic, to: format) }
        self.resultsTask = resultsTask

        // セッション公開までに待避しておいた「録音頭」を、順序を保ったまま流し込む。
        // ロックを保持したまま行うのが要点で、こうしないとオーディオスレッドの feed() が
        // 割り込んで新しいバッファを先に yield し、頭と胴が入れ替わる。
        if let conv = self.converter {
            for pending in pendingBuffers {
                convertAndYieldLocked(pending, builder: builder, format: format, converter: conv)
            }
        }
        pendingBuffers.removeAll()
        pendingFrames = 0
        isBuffering = false
    }

    public func startSession() async throws -> AsyncStream<TranscriptUpdate> {
        try await startSessionInternal().stream
    }

    /// warmUp() が「自分が開始したセッションだけ」を安全に破棄できるよう、
    /// 公開したセッション ID も一緒に返す内部版。
    private func startSessionInternal() async throws
        -> (stream: AsyncStream<TranscriptUpdate>, session: UUID) {
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
        let session = UUID()

        // start() が成功するまでは analyzer/builder はただのローカル変数であり、
        // self には一切公開しない。こうすることで、start() の await 中に外部から
        // cancelSession() が呼ばれても、まだ開始し切っていない analyzer を
        // 掴んでしまうことがない（この間の feed() は inputBuilder が nil なので
        // 待避バッファ側へ回り、publishSessionState で順序どおり流し込まれる）。
        try await analyzer.start(inputSequence: inputSequence)

        // 結果ストリームの購読タスクは、公開より前にここで作っておく。
        // transcriber.results は「音声が供給されて初めて結果が出る」ものであり、
        // inputBuilder はまだ self に公開されていない（feed() は self.inputBuilder が
        // nil のガードで弾く）ため、analyzer.start() 直後のこの時点では
        // transcriber.results に本物の結果が到着することはあり得ない。つまり
        // guard self.currentSession() == session が「公開前」に評価されて
        // 早期 break してしまう実害は無い（本物の結果は必ず公開後・feed 開始後にしか
        // 来ないため、その頃には publishSessionState 済みで guard は必ず通る）。
        // これにより resultsTask を publishSessionState と同じロックでまとめて
        // 公開でき、「4項目は公開済みだが resultsTask だけ未設定」という中間状態を作らない。
        let (updates, updateCont) = AsyncStream<TranscriptUpdate>.makeStream()
        let task = Task { [weak self] in
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    guard let self, self.currentSession() == session else { break }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        updateCont.yield(TranscriptUpdate(displayText: finalized, finalizedSegment: text))
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

        // start() 成功後に初めてセッション（resultsTask を含む）を「公開」する。
        publishSessionState(
            session: session, analyzer: analyzer, transcriber: transcriber,
            builder: builder, format: format, resultsTask: task)

        return (updates, session)
    }

    /// 起動時の予熱。SpeechAnalyzer を一度起動して即破棄し、音声モデルと
    /// speech デーモンをメモリに載せておく。初回のホットキー押下で
    /// analyzer.start() のロード時間（数百ms〜数秒）を払わなくて済む。
    /// 予熱中に本番の録音が割り込んだ場合は、そちらのセッションには一切触れない。
    public func warmUp() async {
        do {
            try await warmUpThrowing()
            Timing.mark("engine.warmUp: ok")
        } catch {
            Timing.mark("engine.warmUp: FAILED \(error)")
        }
    }

    private func warmUpThrowing() async throws {
        let started = try await startSessionInternal()
        guard let claimed = claimIfCurrent(started.session) else { return }
        claimed.builder?.finish()
        claimed.resultsTask?.cancel()
        await claimed.analyzer?.cancelAndFinishNow()
    }

    /// 指定セッションが現行のときだけ資源をクレームする。予熱の後始末が
    /// 「割り込んで公開された本番セッション」を巻き込んで破棄するのを防ぐ。
    private func claimIfCurrent(_ session: UUID) -> ClaimedResources? {
        lock.lock(); defer { lock.unlock() }
        guard sessionID == session else { return nil }
        let claimed = ClaimedResources(
            builder: inputBuilder, analyzer: analyzer, resultsTask: resultsTask,
            transcriber: transcriber, converter: converter)
        inputBuilder = nil
        analyzer = nil
        resultsTask = nil
        transcriber = nil
        converter = nil
        sessionID = UUID()
        return claimed
    }

    private func currentSession() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return sessionID
    }

    /// 変換と yield はロックを保持したまま行う（呼び出し元が lock 済みであること）。
    /// AVAudioConverter はサンプルレート変換の内部状態を持つため、待避バッファの
    /// 流し込みと通常の feed が同時に走ると順序も変換状態も壊れる。
    /// installTap のコールバックは AVAudioEngine の内部直列キュー（レンダースレッドではない）
    /// から呼ばれるため、この程度のロック保持は許容できる。
    private func convertAndYieldLocked(
        _ buffer: AVAudioPCMBuffer,
        builder: AsyncStream<AnalyzerInput>.Continuation,
        format: AVAudioFormat,
        converter: AVAudioConverter
    ) {
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

    public func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let builder = inputBuilder, let format = analysisFormat, let converter else {
            // セッション未公開。beginBuffering() 済みなら捨てずに待避する。
            // タップのバッファはコールバック内でしか有効でないため必ずコピーする。
            guard isBuffering, let copy = Self.copyBuffer(buffer) else { return }
            pendingBuffers.append(copy)
            pendingFrames += Int(copy.frameLength)
            let limit = Int(buffer.format.sampleRate * Self.maxBufferedSeconds)
            while pendingFrames > limit, let oldest = pendingBuffers.first {
                pendingFrames -= Int(oldest.frameLength)
                pendingBuffers.removeFirst()
            }
            return
        }
        convertAndYieldLocked(buffer, builder: builder, format: format, converter: converter)
    }

    /// タップから渡されたバッファのディープコピー。interleaved / non-interleaved の
    /// どちらでも扱えるよう AudioBufferList 単位で memcpy する
    /// （システム音声タップは interleaved、マイクは non-interleaved）。
    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let from = src[i].mData, let to = dst[i].mData else { return nil }
            let bytes = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
            memcpy(to, from, bytes)
            dst[i].mDataByteSize = UInt32(bytes)
        }
        return out
    }

    /// NSLock.lock()/unlock() は async 関数の本体から直接呼べない
    /// （async-safe scoped locking を要求されるため）。同期メソッドに切り出して呼ぶ。
    /// 1回のロック取得で5フィールド全てをクレーム（nil化）して返すことで、
    /// finishAndTranscript() と cancelSession() が同じ SpeechAnalyzer を同時に
    /// 触ってしまう競合や、他セッションの transcriber/converter を巻き込んで
    /// 消してしまう競合を防ぐ。newSessionID を渡すと同時に sessionID も更新する
    /// （cancelSession 用: 遅延結果を無効化）。
    private func claimSessionResources(newSessionID: UUID? = nil) -> ClaimedResources {
        lock.lock(); defer { lock.unlock() }
        let claimed = ClaimedResources(
            builder: inputBuilder,
            analyzer: analyzer,
            resultsTask: resultsTask,
            transcriber: transcriber,
            converter: converter
        )
        inputBuilder = nil
        analyzer = nil
        resultsTask = nil
        transcriber = nil
        converter = nil
        if let newSessionID { sessionID = newSessionID }
        return claimed
    }

    public func finishAndTranscript() async throws -> String {
        let claimed = claimSessionResources()
        guard let builder = claimed.builder, let analyzer = claimed.analyzer else {
            throw EngineError.notStarted
        }
        do {
            builder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            claimed.resultsTask?.cancel()
            throw error
        }
        return await claimed.resultsTask?.value ?? ""
    }

    public func cancelSession() async {
        let claimed = claimSessionResources(newSessionID: UUID())  // 遅延結果を無効化
        claimed.builder?.finish()
        claimed.resultsTask?.cancel()
        await claimed.analyzer?.cancelAndFinishNow()
    }
}
