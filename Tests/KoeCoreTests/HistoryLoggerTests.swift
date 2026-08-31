import Foundation
import Testing
@testable import KoeCore

@Suite struct HistoryLoggerTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func 一行JSONで追記される() throws {
        let dir = tempDir()
        let logger = HistoryLogger(directory: dir)
        try logger.append(text: "テスト1", mode: "raw")
        try logger.append(text: "改行\n入り", mode: "refined")
        let content = try String(contentsOf: dir.appendingPathComponent("history.jsonl"), encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        #expect(first["text"] as? String == "テスト1")
        #expect(first["mode"] as? String == "raw")
        #expect(first["ts"] is String)
    }

    @Test func 上限超過でローテーションする() throws {
        let dir = tempDir()
        let logger = HistoryLogger(directory: dir, maxBytes: 200)
        for i in 0..<20 {
            try logger.append(text: "エントリ\(i) " + String(repeating: "あ", count: 30), mode: "raw")
        }
        let rotated = dir.appendingPathComponent("history.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let current = try Data(contentsOf: dir.appendingPathComponent("history.jsonl"))
        #expect(current.count <= 400)  // 直近分だけが残る
    }
}
