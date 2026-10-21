import Foundation

/// 参考音声 WAV の横に置くサイドカー JSON（同名 .json）。
/// `{"text": "...", "sample_rate": 48000, "duration_sec": 3.6, "device": "...", "recorded_at": "ISO8601"}`
public struct ReferenceSidecar: Codable, Equatable, Sendable {
    public var text: String
    public var sampleRate: Int
    public var durationSec: Double
    public var device: String
    public var recordedAt: String

    enum CodingKeys: String, CodingKey {
        case text
        case sampleRate = "sample_rate"
        case durationSec = "duration_sec"
        case device
        case recordedAt = "recorded_at"
    }

    public init(text: String, sampleRate: Int, durationSec: Double, device: String, recordedAt: Date) {
        self.text = text
        self.sampleRate = sampleRate
        // 小数第3位までに丸める（JSON の見た目のため。精度は十分）
        self.durationSec = (durationSec * 1000).rounded() / 1000
        self.device = device
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        self.recordedAt = f.string(from: recordedAt)
    }

    /// キー順を固定し、日本語をエスケープせずに書く。
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> ReferenceSidecar {
        try JSONDecoder().decode(ReferenceSidecar.self, from: Data(contentsOf: url))
    }

    /// WAV の URL から対応するサイドカーの URL（拡張子を .json に差し替え）。
    public static func url(for wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("json")
    }
}
