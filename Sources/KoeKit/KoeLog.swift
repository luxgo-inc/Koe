import Foundation
import os

/// ローカル専用の動作ログ（~/Library/Logs/Koe/koe.log）。外部送信はしない。
/// クラッシュ原因の切り分け用に「直前に何をしていたか」を残すのが目的なので、
/// 書き起こし本文などの内容は書かず、イベントと数値だけを記録すること。
/// 同じ内容を os.Logger（subsystem: jp.luxgo.koe）にも流すため `log show` でも追える。
public enum KoeLog {
    public static let directory: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Koe", isDirectory: true)
    public static let fileURL = directory.appendingPathComponent("koe.log")
    /// これを超えたら koe.log.1 に退避して作り直す（1世代のみ保持）。
    private static let maxBytes: UInt64 = 2 * 1024 * 1024

    private static let queue = DispatchQueue(label: "jp.luxgo.koe.log")
    private static let logger = Logger(subsystem: "jp.luxgo.koe", category: "app")
    nonisolated(unsafe) private static var handle: FileHandle?
    // queue 上でのみ使う
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        if level == "ERROR" {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(level)] \(message)\n"
            guard let h = openHandle() else { return }
            h.write(Data(line.utf8))
            if let size = try? h.offset(), size > maxBytes { rotate() }
        }
    }

    /// queue 上でのみ呼ぶ。
    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? h.seekToEnd()
        handle = h
        return h
    }

    /// queue 上でのみ呼ぶ。
    private static func rotate() {
        try? handle?.close()
        handle = nil
        let old = directory.appendingPathComponent("koe.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
