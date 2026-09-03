import AVFoundation
import Foundation
import KoeCore
import KoeKit
import Observation

/// iOS 版の録音セッション。macOS の MeetingRecorder のマイク単系統版。
/// マイク → AppleSpeechEngine（オンデバイス）→ 停止時に Markdown 議事録を
/// Documents/meetings へ保存し、Google サインイン済みならアップロードキューに積む。
@MainActor
@Observable
final class MeetingSession {
    private(set) var isRecording = false
    private(set) var isFinishing = false
    private(set) var isPreparing = false
    /// 保存処理の進行状況表示（「話者を判定中…」等）
    private(set) var finishingStatus = ""
    private(set) var startedAt: Date?
    private(set) var liveText = ""
    private(set) var level: Float = 0
    private(set) var lastSavedURL: URL?
    private(set) var errorMessage: String?

    static let meetingsDir: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("meetings")

    private let recorder = AudioRecorder()
    private let engine = AppleSpeechEngine()
    private let audioSession = AudioSessionController()
    private let store = MeetingStore(directory: MeetingSession.meetingsDir)
    private var builder = MeetingTranscriptBuilder()
    /// 確定セグメントの蓄積（話者未定のまま貯め、停止時に話者分離結果でラベル付けする）
    private var rawSegments: [RawSegment] = []
    private var diarizationWriter: DiarizationAudioWriter?
    private var consumeTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var didPrepare = false
    let settings = AppSettings()

    /// 3時間の安全弁（止め忘れ対策）。macOS 版と同じ。
    static let maxDuration: Duration = .seconds(3 * 60 * 60)

    struct RawSegment {
        let text: String
        /// 音声タイムライン上の範囲（SpeechModuleResult.range 由来）。取れなければ nil
        let audioStart: Double?
        let audioEnd: Double?
        /// 確定到着時刻ベースの秒（フォールバック用タイムスタンプ）
        let arrivalSeconds: Double
    }

    private var diarizationEnabled: Bool {
        UserDefaults.standard.object(forKey: "diarizationEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "diarizationEnabled")
    }

    func start() async {
        guard !isRecording, !isFinishing else { return }
        errorMessage = nil
        liveText = ""
        builder = MeetingTranscriptBuilder()
        rawSegments = []

        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                errorMessage = "マイクの使用が許可されていません（設定アプリ > プライバシー > マイク）"
                return
            }
            if !didPrepare {
                isPreparing = true
                defer { isPreparing = false }
                try await engine.prepare()  // 初回はオンデバイスモデルのDLが走る（Wi-Fi推奨）
                didPrepare = true
            }
            try audioSession.activate()
            audioSession.onInterruptionEnded = { [weak self] in
                // 電話着信などの割り込みが明けたら録音エンジンだけ再起動する
                guard let self, self.isRecording else { return }
                try? self.recorder.start()
            }
            let start = Date()

            // configureMicFormat は必ず startSession より前に呼ぶ
            // （converter 未生成のまま feed が全バッファを捨てるのを防ぐ。macOS 版と同じ制約）。
            // iOS では AVAudioSession を有効化した後でないと正しい入力フォーマットが取れない。
            engine.configureMicFormat(recorder.inputFormat)
            let updates = try await engine.startSession()
            consumeTask = consume(updates, start: start)

            // 話者分離用に 16kHz モノラルを並行蓄積（モデルDLは停止時に必要なら走る）
            var writer: DiarizationAudioWriter?
            if diarizationEnabled {
                let w = DiarizationAudioWriter()
                try? w.start()
                writer = w
            }
            diarizationWriter = writer

            let engineRef = engine
            let writerRef = writer
            recorder.onBuffer = { @Sendable buffer in
                engineRef.feed(buffer)
                writerRef?.append(buffer)
            }
            recorder.onLevel = { @Sendable [weak self] lv in
                Task { @MainActor in self?.level = lv }
            }
            try recorder.start()

            startedAt = start
            isRecording = true
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(for: Self.maxDuration)
                guard !Task.isCancelled else { return }
                await self?.stopAndSave()
            }
        } catch {
            teardownCapture()
            await engine.cancelSession()
            audioSession.deactivate()
            diarizationWriter?.discard()
            diarizationWriter = nil
            errorMessage = "開始に失敗しました: \(error.localizedDescription)"
        }
    }

    private func consume(_ updates: AsyncStream<TranscriptUpdate>, start: Date) -> Task<Void, Never> {
        Task { [weak self] in
            for await update in updates {
                self?.liveText = update.displayText
                guard let segment = update.finalizedSegment else { continue }
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                self?.rawSegments.append(RawSegment(
                    text: trimmed,
                    audioStart: update.finalizedStartSeconds,
                    audioEnd: update.finalizedEndSeconds,
                    arrivalSeconds: Date().timeIntervalSince(start)))
            }
        }
    }

    private func teardownCapture() {
        recorder.onBuffer = nil
        recorder.onLevel = nil
        recorder.stop()
        level = 0
    }

    /// finishAndTranscript に watchdog を付ける（macOS 版と同じ）。
    /// タイムアウト時は cancelSession で打ち切り、確定済みセグメントだけで議事録を作る。
    private static func finishOrCancel(_ engine: AppleSpeechEngine, timeout: Duration) async {
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await engine.finishAndTranscript()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            await engine.cancelSession()
        }
    }

    func stopAndSave() async {
        guard isRecording, !isFinishing else { return }
        isFinishing = true
        isRecording = false
        autoStopTask?.cancel()
        autoStopTask = nil
        let start = startedAt ?? Date()
        startedAt = nil

        finishingStatus = "文字起こしを確定中…"
        teardownCapture()
        await Self.finishOrCancel(engine, timeout: .seconds(30))
        if let consumeTask { await consumeTask.value }
        consumeTask = nil
        audioSession.deactivate()
        let audioFile = diarizationWriter?.finish()
        diarizationWriter = nil

        defer {
            isFinishing = false
            finishingStatus = ""
            if let audioFile { try? FileManager.default.removeItem(at: audioFile) }
        }
        guard !rawSegments.isEmpty else {
            errorMessage = "音声を認識できませんでした（保存なし）"
            return
        }

        // 話者分離: 蓄積した 16kHz 音声をダイアライゼーションし、各セグメントにラベル付け。
        // 失敗時（モデル未DL・オフライン初回等）は「発言」ラベルで保存にフォールバックする。
        var spans: [DiarizationService.SpeakerSpan] = []
        if diarizationEnabled, let audioFile {
            finishingStatus = "話者を判定中…"
            do {
                spans = try await DiarizationService.shared.diarize(fileURL: audioFile)
            } catch {
                spans = []
            }
        }
        builder = MeetingTranscriptBuilder()
        for seg in rawSegments {
            var speaker = "発言"
            if !spans.isEmpty, let s0 = seg.audioStart, let s1 = seg.audioEnd,
               let label = DiarizationService.speaker(for: (s0, s1), in: spans) {
                speaker = label
            }
            builder.add(
                speaker: speaker,
                seconds: seg.audioStart ?? seg.arrivalSeconds,
                text: seg.text)
        }
        finishingStatus = "保存中…"

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "ja_JP")
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let duration = MeetingTranscriptBuilder.timestamp(Date().timeIntervalSince(start))
        let title = "会議メモ \(dateFmt.string(from: start))（\(duration)）"
        var markdown = builder.renderMarkdown(title: title)

        // AI整形ONのときだけ要約を付与（OFFなら完全オンデバイスで完結）
        if settings.aiRefinementEnabled {
            let service = RefinementService(timeout: .seconds(45))
            let (summary, fallbackReason) = await service.refine(
                builder.plainText(),
                modelID: settings.modelID,
                instruction: MeetingSummaryPrompt.instruction)
            if fallbackReason == nil {
                var body = ["# \(title)", "", summary, "", "## 全文書き起こし", ""]
                body.append(contentsOf: builder.renderMarkdown(title: title)
                    .split(separator: "\n").dropFirst().map(String.init))
                markdown = body.joined(separator: "\n") + "\n"
            }
        }

        do {
            let url = try store.save(markdown: markdown, date: start)
            lastSavedURL = url
            liveText = ""
            UploadQueue.shared.enqueue(url)
            await UploadQueue.shared.drain()
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }
}
