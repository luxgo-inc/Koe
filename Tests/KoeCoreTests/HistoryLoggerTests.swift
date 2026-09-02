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

    @Test func エントリを古い順に読み戻せる() throws {
        let dir = tempDir()
        let logger = HistoryLogger(directory: dir)
        try logger.append(text: "一件目", mode: "raw")
        try logger.append(text: "二件目", mode: "refined")
        let entries = logger.entries()
        #expect(entries.count == 2)
        #expect(entries[0].text == "一件目")
        #expect(entries[0].mode == "raw")
        #expect(entries[1].text == "二件目")
    }

    @Test func ローテーション後も両世代を読める() throws {
        let dir = tempDir()
        let logger = HistoryLogger(directory: dir, maxBytes: 200)
        for i in 0..<10 {
            try logger.append(text: "エントリ\(i) " + String(repeating: "あ", count: 40), mode: "raw")
        }
        let entries = logger.entries()
        // 1世代ローテーションのため古いものは失われてよいが、
        // .1(旧世代) + 現行 の両方が読め、直近エントリは必ず残り、順序は古い→新しい
        #expect(!entries.isEmpty)
        #expect(entries.count < 10)
        #expect(entries.last?.text.hasPrefix("エントリ9") == true)
        let indices = entries.map { Int($0.text.dropFirst("エントリ".count).prefix(1))! }
        #expect(indices == indices.sorted())
        // 旧世代ファイルも実在して読まれている
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.jsonl.1").path))
    }

    @Test func 破損行はスキップされる() throws {
        let dir = tempDir()
        let logger = HistoryLogger(directory: dir)
        try logger.append(text: "正常", mode: "raw")
        let file = dir.appendingPathComponent("history.jsonl")
        var data = try Data(contentsOf: file)
        data.append(Data("oops not json\n".utf8))
        try data.write(to: file)
        try logger.append(text: "後続", mode: "raw")
        let entries = logger.entries()
        #expect(entries.map(\.text) == ["正常", "後続"])
    }

    @Test func remove_clearで削除できる() throws {
        let dir = tempDir()
        let logger = HistoryLogger(directory: dir)
        try logger.append(text: "残す", mode: "raw")
        try logger.append(text: "消す", mode: "raw")
        let target = logger.entries().first { $0.text == "消す" }!
        try logger.remove(target)
        #expect(logger.entries().map(\.text) == ["残す"])
        try logger.clear()
        #expect(logger.entries().isEmpty)
    }
}
