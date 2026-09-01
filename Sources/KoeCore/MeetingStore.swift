import Foundation

/// 議事録 Markdown のファイル保存。保存先ディレクトリは呼び出し側が注入する
/// （本番: Application Support/Koe/meetings）。
public struct MeetingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for date: Date, timeZone: TimeZone = .current) -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return directory.appendingPathComponent("\(fmt.string(from: date))-meeting.md")
    }

    @discardableResult
    public func save(markdown: String, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: date)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
