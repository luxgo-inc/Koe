import AppKit
import Darwin
import Foundation
import KoeKit
import KoeObjC

/// ローカル専用のクラッシュ記録（外部送信なし）。保存先は ~/Library/Logs/Koe/crashes/。
///
/// 1. Objective-C 例外: AppKit は既定で runloop 上の例外を握りつぶして処理を続ける。
///    Swift のフレームを例外が突き抜けると Swift Concurrency の実行状態が壊れ、
///    数ms後に無関係な場所（MenuBarExtra の body 等）で SIGSEGV になって原因が
///    追えなくなる（2026-10-16/18 の実例）。握りつぶされる瞬間をフックして理由と
///    スタックを exception-*.log に残す。NSApplicationCrashOnExceptions で即落ちに
///    すると無害な例外まで落ちる（ブース等での常用に不向き）ため、挙動は変えない。
///    別スレッドの未捕捉例外は NSSetUncaughtExceptionHandler で同様に残す。
/// 2. シグナル（SIGSEGV 等）: signal-*.log にシグナル番号とバックトレースを書いてから
///    既定動作に戻して再送出する（macOS 標準のクラッシュレポート .ips も従来どおり出る）。
/// 3. 次回起動時: 前回が異常終了だったかを koe.log に記録し、macOS が
///    ~/Library/Logs/DiagnosticReports に出した KoeApp-*.ips を crashes/ へ回収する。
enum CrashReporter {
    static let directory = KoeLog.directory.appendingPathComponent("crashes", isDirectory: true)
    private static let runningMarker = KoeLog.directory.appendingPathComponent("running.marker")

    @MainActor
    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        KoeObjCException.observeAppKitReportedExceptions { exception in
            CrashReporter.writeException(exception, fatal: false)
        }
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeException(exception, fatal: true)
        }
        installSignalHandlers()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        if fm.fileExists(atPath: runningMarker.path) {
            let previous = (try? String(contentsOf: runningMarker, encoding: .utf8)) ?? ""
            KoeLog.error("前回の起動（\(previous.trimmingCharacters(in: .whitespacesAndNewlines))）は正常終了していません（クラッシュ / 強制終了 / メモリ枯渇による kill の可能性）")
        }
        try? "pid=\(getpid()) launched=\(Date())".write(to: runningMarker, atomically: true, encoding: .utf8)
        KoeLog.info("起動: version=\(version) build=\(build) pid=\(getpid()) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            KoeLog.info("正常終了")
            try? FileManager.default.removeItem(at: runningMarker)
        }

        DispatchQueue.global(qos: .utility).async { collectSystemReports() }
    }

    // MARK: - Objective-C 例外

    private static func writeException(_ exception: NSException, fatal: Bool) {
        let body = """
        Koe \(fatal ? "uncaught exception (fatal)" : "exception caught by AppKit（処理は続行され得る。直後のクラッシュはこれが原因の可能性大）")
        time: \(Date())
        name: \(exception.name.rawValue)
        reason: \(exception.reason ?? "(none)")
        userInfo: \(exception.userInfo ?? [:])

        callStack:
        \(exception.callStackSymbols.joined(separator: "\n"))

        """
        let url = directory.appendingPathComponent("exception-\(timestamp()).log")
        try? body.write(to: url, atomically: false, encoding: .utf8)
        KoeLog.error("\(fatal ? "未捕捉の例外で終了" : "AppKitが例外を捕捉"): \(exception.name.rawValue): \(exception.reason ?? "") → \(url.lastPathComponent)")
    }

    // MARK: - シグナル

    /// シグナルハンドラ内では malloc 等を使えないため、パスは起動時に C 文字列で確保しておく。
    nonisolated(unsafe) private static var signalLogPath: UnsafeMutablePointer<CChar>?
    private static let maxFrames: Int32 = 128
    nonisolated(unsafe) private static var frameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT]

    private static func installSignalHandlers() {
        let path = directory.appendingPathComponent("signal-\(timestamp())-pid\(getpid()).log").path
        signalLogPath = strdup(path)
        frameBuffer = .allocate(capacity: Int(maxFrames))
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                CrashReporter.handleSignal(sig)
            }
            sigemptyset(&action.sa_mask)
            // SA_RESETHAND: 一度呼ばれたら既定動作に戻る（再送出で通常どおり落ちて .ips が出る）
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
    }

    /// async-signal-safe な呼び出し（open / write / backtrace_symbols_fd / raise）だけで書く。
    private static func handleSignal(_ sig: Int32) {
        if let path = signalLogPath, let frames = frameBuffer {
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                writeRaw(fd, "Koe fatal signal ")
                writeRaw(fd, signalName(sig))
                writeRaw(fd, "\nbacktrace:\n")
                let count = backtrace(frames, maxFrames)
                backtrace_symbols_fd(frames, count, fd)
                close(fd)
            }
        }
        raise(sig)
    }

    private static func writeRaw(_ fd: Int32, _ s: StaticString) {
        _ = write(fd, s.utf8Start, s.utf8CodeUnitCount)
    }

    private static func signalName(_ sig: Int32) -> StaticString {
        switch sig {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGFPE: "SIGFPE"
        case SIGTRAP: "SIGTRAP (Swift runtime error)"
        case SIGABRT: "SIGABRT"
        default: "unknown"
        }
    }

    // MARK: - macOS クラッシュレポートの回収

    /// DiagnosticReports（と Retired）にある KoeApp-*.ips のうち未回収のものを crashes/ へコピーし、
    /// 例外種別と落ちた箇所の要約を koe.log に1行残す。
    private static func collectSystemReports() {
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports")
        for dir in [base, base.appendingPathComponent("Retired")] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("KoeApp") && name.hasSuffix(".ips") {
                let dest = directory.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                let src = dir.appendingPathComponent(name)
                guard (try? fm.copyItem(at: src, to: dest)) != nil else { continue }
                KoeLog.error("macOS のクラッシュレポートを回収: \(name) — \(summarize(dest))")
            }
        }
    }

    /// .ips は「1行目: ヘッダ JSON / 2行目以降: 本体 JSON」の形式。
    private static func summarize(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let newline = text.firstIndex(of: "\n"),
              let data = text[text.index(after: newline)...].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "要約できませんでした" }
        let exception = root["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? "?"
        let signal = exception?["signal"] as? String ?? ""
        var frames: [String] = []
        if let threads = root["threads"] as? [[String: Any]],
           let faulting = root["faultingThread"] as? Int, faulting < threads.count,
           let stack = threads[faulting]["frames"] as? [[String: Any]] {
            frames = stack.prefix(8).compactMap { $0["symbol"] as? String }
        }
        return "\(type) \(signal) at \(frames.joined(separator: " ← "))"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
