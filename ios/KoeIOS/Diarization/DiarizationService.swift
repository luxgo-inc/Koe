import FluidAudio
import Foundation

/// FluidAudio（pyannote/CoreML）による話者分離。actor なので重い推論はメインスレッド外で走る。
/// 声紋登録済みなら「自分」を識別し、それ以外は登場順に「話者1」「話者2」…と割り当てる。
actor DiarizationService {
    static let shared = DiarizationService()

    struct SpeakerSpan: Sendable {
        let label: String
        let start: Double
        let end: Double
    }

    enum ServiceError: LocalizedError {
        case audioTooShort
        var errorDescription: String? {
            switch self {
            case .audioTooShort: return "音声が短すぎて声紋を抽出できませんでした（10秒以上話してください）"
            }
        }
    }

    static let selfSpeakerID = "self"
    static let selfLabel = "自分"

    private var diarizer: DiarizerManager?

    private static let embeddingFile: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("self-voice-embedding.json")

    /// モデルの確認・ダウンロード（初回のみDL、以後はローカルキャッシュ）。
    func prepare() async throws {
        guard diarizer == nil else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        diarizer = manager
    }

    var isReady: Bool { diarizer != nil }

    // MARK: - 声紋登録

    nonisolated static var hasSelfEmbedding: Bool {
        FileManager.default.fileExists(atPath: embeddingFile.path)
    }

    /// 自分の声（16kHz モノラル Float32）から声紋を抽出して保存する。
    func enrollSelf(samples: [Float]) async throws {
        try await prepare()
        guard samples.count >= Int(DiarizationAudioWriter.sampleRate) * 5 else {
            throw ServiceError.audioTooShort
        }
        let embedding = try diarizer!.extractSpeakerEmbedding(from: samples)
        let data = try JSONEncoder().encode(embedding)
        try data.write(to: Self.embeddingFile, options: .atomic)
    }

    func removeSelfEmbedding() {
        try? FileManager.default.removeItem(at: Self.embeddingFile)
    }

    private func loadSelfEmbedding() -> [Float]? {
        guard let data = try? Data(contentsOf: Self.embeddingFile) else { return nil }
        return try? JSONDecoder().decode([Float].self, from: data)
    }

    // MARK: - 話者分離

    /// 16kHz モノラル Float32 生バイナリのファイルを話者分離し、話者ラベル付き時間区間を返す。
    /// ファイルは mmap で読むため長時間録音でもメモリ負荷は抑えられる。
    func diarize(fileURL: URL) async throws -> [SpeakerSpan] {
        try await prepare()
        let diarizer = self.diarizer!

        // 会議ごとに話者データベースをリセットし、登録済みの「自分」だけを既知話者として与える
        if let selfEmbedding = loadSelfEmbedding() {
            diarizer.speakerManager.initializeKnownSpeakers(
                [Speaker(
                    id: Self.selfSpeakerID, name: Self.selfLabel,
                    currentEmbedding: selfEmbedding, isPermanent: true)],
                mode: .reset, preserveIfPermanent: false)
        } else {
            diarizer.speakerManager.reset(keepIfPermanent: false)
        }

        let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
        let result: DiarizationResult = try data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            return try diarizer.performCompleteDiarization(
                samples, sampleRate: Int(DiarizationAudioWriter.sampleRate))
        }

        // speakerId（自分 or 内部ID）→ 表示ラベルへ登場順で変換
        var labels: [String: String] = [Self.selfSpeakerID: Self.selfLabel]
        var nextIndex = 1
        var spans: [SpeakerSpan] = []
        for segment in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            guard !segment.speakerId.isEmpty else { continue }
            let label: String
            if let known = labels[segment.speakerId] {
                label = known
            } else {
                label = "話者\(nextIndex)"
                nextIndex += 1
                labels[segment.speakerId] = label
            }
            spans.append(SpeakerSpan(
                label: label,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)))
        }
        return spans
    }

    /// 文字起こしセグメントの時間範囲に最も重なる話者ラベルを返す。
    /// 重なりが無い場合は中心時刻に最も近い区間の話者を使う。どちらも無ければ nil。
    nonisolated static func speaker(
        for range: (start: Double, end: Double), in spans: [SpeakerSpan]
    ) -> String? {
        var best: (label: String, overlap: Double)?
        for span in spans {
            let overlap = min(range.end, span.end) - max(range.start, span.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (span.label, overlap)
            }
        }
        if let best { return best.label }
        let mid = (range.start + range.end) / 2
        return spans.min {
            distance(from: mid, to: $0) < distance(from: mid, to: $1)
        }?.label
    }

    private nonisolated static func distance(from time: Double, to span: SpeakerSpan) -> Double {
        if time < span.start { return span.start - time }
        if time > span.end { return time - span.end }
        return 0
    }
}
