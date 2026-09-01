import Foundation

public struct MeetingSegment: Equatable, Sendable {
    public let speaker: String
    public let seconds: TimeInterval
    public let text: String
}

/// 会議中に確定した発話セグメントを蓄積し、時刻順の Markdown 議事録に描画する。
/// マイク系統とシステム音声系統の finalize 到着順は前後し得るため、描画時に
/// seconds でソートする（同時刻は追加順を保持）。
public struct MeetingTranscriptBuilder: Sendable {
    private var segments: [MeetingSegment] = []

    public init() {}

    public var isEmpty: Bool { segments.isEmpty }

    public mutating func add(speaker: String, seconds: TimeInterval, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(MeetingSegment(speaker: speaker, seconds: seconds, text: trimmed))
    }

    private var sorted: [MeetingSegment] {
        segments.enumerated()
            .sorted { ($0.element.seconds, $0.offset) < ($1.element.seconds, $1.offset) }
            .map(\.element)
    }

    public func renderMarkdown(title: String) -> String {
        var lines = ["# \(title)", ""]
        for seg in sorted {
            lines.append("- [\(Self.timestamp(seg.seconds))] **\(seg.speaker)**: \(seg.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// AI要約に渡す用のプレーンテキスト。
    public func plainText() -> String {
        sorted.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
