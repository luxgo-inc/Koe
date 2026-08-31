import Foundation

/// 確定テキストの jsonl 追記ログ。デフォルト OFF（呼び出し側が historyEnabled を見る）。
/// maxBytes 超過で history.jsonl → history.jsonl.1 にローテーション（1世代のみ）。
public struct HistoryLogger: Sendable {
    let directory: URL
    let maxBytes: Int

    public init(directory: URL, maxBytes: Int = 1_000_000) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public func append(text: String, mode: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.jsonl")
        rotateIfNeeded(file: file)
        let entry: [String: String] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mode": mode,
            "text": text,
        ]
        var line = try JSONSerialization.data(withJSONObject: entry)
        line.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
    }

    private func rotateIfNeeded(file: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int,
              size >= maxBytes else { return }
        let rotated = directory.appendingPathComponent("history.jsonl.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: file, to: rotated)
    }
}
