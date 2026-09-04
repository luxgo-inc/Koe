import AppKit
import AVFoundation
import Foundation
import KoeCore
import KoeDiarization
import KoeKit
import UserNotifications

/// 会議録音モード: マイク（自分）とシステム音声（相手）を並行キャプチャし、
/// AppleSpeechEngine 2系統で文字起こし→停止時に Markdown 議事録を保存する。
/// 話者分離ONのときはシステム音声を FluidAudio でダイアライゼーションし、
/// リモート会議の相手を「話者1」「話者2」…に切り分ける（マイク側は常に「自分」）。
/// F9/F10 の通常音声入力（RecordingController）とは完全に独立したインスタンス群で動く。
@MainActor
@Observable
final class MeetingRecorder {
    private(set) var isRecording = false
    private(set) var isFinishing = false
    private(set) var startedAt: Date?
    private(set) var lastSavedURL: URL?
    private(set) var errorMessage: String?

    static let meetingsDir = RecordingController.appSupportDir.appendingPathComponent("meetings")

    private let micRecorder = AudioRecorder()
    private let micEngine = AppleSpeechEngine()
    private let systemCapture = SystemAudioCapture()
    private let systemEngine = AppleSpeechEngine()
    private let store = MeetingStore(directory: MeetingRecorder.meetingsDir)
    private var builder = MeetingTranscriptBuilder()
    /// 確定セグメントの蓄積（話者未定のまま貯め、停止時に話者分離結果でラベル付けする）。
    /// MainActor 隔離なので consume タスクからの append と停止時の読み出しは直列化される。
    private var rawSegments: [RawSegment] = []
    /// 話者分離用にシステム音声の 16kHz モノラルを並行蓄積するライター（分離OFFなら nil）
    private var diarizationWriter: DiarizationAudioWriter?
    private var consumeTasks: [Task<Void, Never>] = []
    private var autoStopTask: Task<Void, Never>?
    private var didPrepare = false
    var settings = AppSettings()

    /// 3時間の安全弁（止め忘れ対策）
    static let maxDuration: Duration = .seconds(3 * 60 * 60)

    /// 確定セグメント。話者ラベルは停止時に決める（iOS 版 MeetingSession.RawSegment と同じ構造）。
    struct RawSegment {
        /// true = システム音声（リモートの相手）、false = マイク（自分）
        let isSystem: Bool
        let text: String
        /// 音声タイムライン上の範囲（SpeechModuleResult.range 由来）。取れなければ nil
        let audioStart: Double?
        let audioEnd: Double?
        /// 確定到着時刻ベースの秒（フォールバック用タイムスタンプ）
        let arrivalSeconds: Double
    }

    func start() async {
        guard !isRecording, !isFinishing else { return }
        errorMessage = nil
        builder = MeetingTranscriptBuilder()
        rawSegments = []

        do {
            if !didPrepare {
                try await micEngine.prepare()
                didPrepare = true
            }
            let start = Date()

            // configureMicFormat は必ず startSession より前に呼ぶ。
            // AppleSpeechEngine はセッション公開時に micFormat から converter を作るため、
            // 後から呼ぶと converter が nil のまま feed() が全バッファを捨て、
            // 入力ゼロで finalize がハングする（v3 初回スモークで実際に発生）。
            micEngine.configureMicFormat(micRecorder.inputFormat)
            let micUpdates = try await micEngine.startSession()

            // システム音声系統はタップ起動後にフォーマットが確定するため、先にタップを開始する
            try systemCapture.start()
            guard let sysFormat = systemCapture.format else {
                throw SystemAudioCapture.CaptureError.formatRead(-1)
            }
            systemEngine.configureMicFormat(sysFormat)
            let sysUpdates = try await systemEngine.startSession()

            consumeTasks = [
                consume(micUpdates, isSystem: false, start: start),
                consume(sysUpdates, isSystem: true, start: start),
            ]

            // 話者分離用にシステム音声の 16kHz モノラルを並行蓄積
            // （モデルDLは停止時に必要なら走る。書き込み失敗時は分離なしで続行）
            var writer: DiarizationAudioWriter?
            if settings.diarizationEnabled {
                let w = DiarizationAudioWriter()
                do {
                    try w.start()
                    writer = w
                } catch {
                    writer = nil
                }
            }
            diarizationWriter = writer

            // セッション公開済みになってからバッファを接続する
            let micEngineRef = micEngine
            micRecorder.onBuffer = { @Sendable buffer in micEngineRef.feed(buffer) }
            try micRecorder.start()
            let sysEngineRef = systemEngine
            let writerRef = writer
            systemCapture.onBuffer = { @Sendable buffer in
                sysEngineRef.feed(buffer)
                writerRef?.append(buffer)
            }

            startedAt = start
            isRecording = true
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(for: Self.maxDuration)
                guard !Task.isCancelled else { return }
                await self?.stopAndSave()
            }
        } catch {
            await teardownCapture()
            await micEngine.cancelSession()
            await systemEngine.cancelSession()
            diarizationWriter?.discard()
            diarizationWriter = nil
            errorMessage = "開始に失敗しました: \(error.localizedDescription)"
        }
    }

    private func consume(
        _ updates: AsyncStream<TranscriptUpdate>, isSystem: Bool, start: Date
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await update in updates {
                guard let segment = update.finalizedSegment else { continue }
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                self?.rawSegments.append(RawSegment(
                    isSystem: isSystem,
                    text: trimmed,
                    audioStart: update.finalizedStartSeconds,
                    audioEnd: update.finalizedEndSeconds,
                    arrivalSeconds: Date().timeIntervalSince(start)))
            }
        }
    }

    private func teardownCapture() async {
        micRecorder.onBuffer = nil
        micRecorder.stop()
        systemCapture.onBuffer = nil
        systemCapture.stop()
    }

    /// finishAndTranscript に watchdog を付ける。タイムアウト時は cancelSession で
    /// セッション資源を破棄し、それまでに確定済みのセグメントだけで議事録を作る。
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

        await teardownCapture()
        // finalize で残りの volatile が確定 → consume タスクがストリーム終端まで拾う。
        // finalize が返らない異常時も UI が「保存中…」で固まらないよう watchdog で打ち切る
        // （打ち切り時は cancelSession が results ストリームを終端させ consume タスクも終わる）。
        await Self.finishOrCancel(micEngine, timeout: .seconds(30))
        await Self.finishOrCancel(systemEngine, timeout: .seconds(30))
        for task in consumeTasks { await task.value }
        consumeTasks = []
        let audioFile = diarizationWriter?.finish()
        diarizationWriter = nil

        defer {
            isFinishing = false
            if let audioFile { try? FileManager.default.removeItem(at: audioFile) }
        }
        guard !rawSegments.isEmpty else {
            errorMessage = "音声を認識できませんでした（保存なし）"
            return
        }

        // 話者分離: システム音声（リモートの相手）をダイアライゼーションし「話者1」「話者2」…を付与。
        // 失敗時（モデル未DL・オフライン初回等）は従来どおり「相手」ラベルにフォールバックする。
        var spans: [DiarizationService.SpeakerSpan] = []
        if settings.diarizationEnabled, let audioFile,
           rawSegments.contains(where: { $0.isSystem }) {
            spans = (try? await DiarizationService.shared.diarize(fileURL: audioFile)) ?? []
        }
        builder = MeetingTranscriptBuilder()
        for seg in rawSegments {
            var speaker = seg.isSystem ? "相手" : "自分"
            if seg.isSystem, !spans.isEmpty, let s0 = seg.audioStart, let s1 = seg.audioEnd,
               let label = DiarizationService.speaker(for: (s0, s1), in: spans) {
                speaker = label
            }
            builder.add(
                speaker: speaker,
                seconds: seg.audioStart ?? seg.arrivalSeconds,
                text: seg.text)
        }

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "ja_JP")
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let duration = MeetingTranscriptBuilder.timestamp(Date().timeIntervalSince(start))
        let title = "会議メモ \(dateFmt.string(from: start))（\(duration)）"
        var markdown = builder.renderMarkdown(title: title)

        // AI整形ONのときだけ要約を付与（オンデバイス完結を保ちたい場合はOFFで運用）
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
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let content = UNMutableNotificationContent()
            content.title = "議事録を保存しました"
            content.body = url.lastPathComponent
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }
}
