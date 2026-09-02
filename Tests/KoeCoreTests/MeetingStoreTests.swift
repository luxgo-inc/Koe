import Foundation
import Testing
@testable import KoeCore

@Suite struct MeetingStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)")
    }

    @Test func ファイル名は日時ベース() {
        let store = MeetingStore(directory: URL(fileURLWithPath: "/tmp/x"))
        var comps = DateComponents(year: 2026, month: 9, day: 1, hour: 14, minute: 30)
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let url = store.fileURL(for: comps.date!, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(url.lastPathComponent == "2026-09-01-1430-meeting.md")
    }

    @Test func saveはディレクトリを作成して書き込みURLを返す() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        let url = try store.save(markdown: "# 会議\n", date: Date())
        #expect(try String(contentsOf: url, encoding: .utf8) == "# 会議\n")
    }
}
