import Foundation
import KoeCore
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
    /// 同じ行の連続をまとめる（queue 上でのみ使う）。暴走時にローテーションで
    /// きっかけの行が押し流されないようにするため、ファイル側だけに効かせる。
    nonisolated(unsafe) private static var repeats = LogRepeatSuppressor()
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
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            let stamp = formatter.string(from: now)
            for output in repeats.process("[\(level)] \(message)", at: uptime) {
                switch output {
                case .line(let body):
                    append("\(stamp) \(body)\n")
                case .repeated(let count):
                    append("\(stamp) [INFO] （直前の行がさらに \(count) 回繰り返されました）\n")
                }
            }
        }
    }

    /// 書き込み待ちのログを書き終えるまで待つ（即時終了の直前に呼ぶ）。
    public static func flush() {
        queue.sync {}
    }

    /// queue 上でのみ呼ぶ。
    private static func append(_ line: String) {
        guard let h = openHandle() else { return }
        // write(_:) は失敗（ディスクフルなど）を NSException で投げてアプリごと落ちるため、
        // throws 版を使う。ログの失敗はログに残さず、次回に開き直させるだけにする。
        do {
            try h.write(contentsOf: Data(line.utf8))
        } catch {
            try? h.close()
            handle = nil
            return
        }
        if let size = try? h.offset(), size > maxBytes { rotate() }
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
