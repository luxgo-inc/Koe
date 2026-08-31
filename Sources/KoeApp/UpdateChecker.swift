import AppKit
import Foundation
import UserNotifications

/// 軽量アップデート: リポジトリの origin/main と比較し、差分があれば
/// Terminal.app で update-app.sh を実行させる（自己差し替え競合を避けるため）。
@MainActor
enum UpdateChecker {
    private static let repoPath = ("~/ghq/github.com/luxgo-inc/Koe" as NSString).expandingTildeInPath

    static func check() {
        Task {
            let result = await checkForUpdates()
            switch result {
            case .upToDate:
                notify("Koe は最新です")
            case .updateAvailable(let count):
                confirmAndUpdate(behindBy: count)
            case .repoMissing:
                notify("リポジトリが見つかりません: \(repoPath)")
            case .error(let message):
                notify("更新確認に失敗しました: \(message)")
            }
        }
    }

    enum CheckResult {
        case upToDate
        case updateAvailable(Int)
        case repoMissing
        case error(String)
    }

    private static func checkForUpdates() async -> CheckResult {
        guard FileManager.default.fileExists(atPath: repoPath + "/.git") else {
            return .repoMissing
        }
        do {
            _ = try await run("/usr/bin/git", ["-C", repoPath, "fetch", "origin", "main"])
            let out = try await run("/usr/bin/git", ["-C", repoPath, "rev-list", "--count", "HEAD..origin/main"])
            let count = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return count == 0 ? .upToDate : .updateAvailable(count)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func confirmAndUpdate(behindBy count: Int) {
        let alert = NSAlert()
        alert.messageText = "アップデートがあります（\(count) コミット）"
        alert.informativeText = "Terminal で更新スクリプトを実行します。アプリは一度終了します。"
        alert.addButton(withTitle: "更新する")
        alert.addButton(withTitle: "あとで")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let script = repoPath + "/scripts/update-app.sh"
        let source = "tell application \"Terminal\" to do script \"bash \(script)\"\n" +
                     "tell application \"Terminal\" to activate"
        if let osa = NSAppleScript(source: source) {
            var errorInfo: NSDictionary?
            osa.executeAndReturnError(&errorInfo)
            if errorInfo == nil {
                NSApplication.shared.terminate(nil)
            } else {
                notify("Terminal の起動に失敗しました")
            }
        }
    }

    private static func run(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "UpdateChecker", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: out]))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Koe"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
