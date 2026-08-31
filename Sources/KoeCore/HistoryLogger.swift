import Foundation

public struct HistoryEntry: Equatable, Sendable {
    public let ts: String
    public let mode: String
    public let text: String
}

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

extension HistoryLogger {
    private var currentFile: URL { directory.appendingPathComponent("history.jsonl") }
    private var rotatedFile: URL { directory.appendingPathComponent("history.jsonl.1") }

    /// 古い順（.1 → 現行）。破損行はスキップ。
    public func entries() -> [HistoryEntry] {
        [rotatedFile, currentFile].flatMap { parse($0) }
    }

    private func parse(_ url: URL) -> [HistoryEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let ts = obj["ts"], let mode = obj["mode"], let text = obj["text"]
            else { return nil }
            return HistoryEntry(ts: ts, mode: mode, text: text)
        }
    }

    /// ts+text+mode が一致する最初の 1 行を削除して書き戻す。
    public func remove(_ entry: HistoryEntry) throws {
        for url in [rotatedFile, currentFile] {
            var kept: [HistoryEntry] = []
            var removed = false
            for e in parse(url) {
                if !removed && e == entry { removed = true; continue }
                kept.append(e)
            }
            if removed {
                try rewrite(url, with: kept)
                return
            }
        }
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: currentFile)
        try? FileManager.default.removeItem(at: rotatedFile)
    }

    private func rewrite(_ url: URL, with entries: [HistoryEntry]) throws {
        var data = Data()
        for e in entries {
            let obj = ["ts": e.ts, "mode": e.mode, "text": e.text]
            data.append(try JSONSerialization.data(withJSONObject: obj))
            data.append(Data("\n".utf8))
        }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try data.write(to: url)
        }
    }
}
