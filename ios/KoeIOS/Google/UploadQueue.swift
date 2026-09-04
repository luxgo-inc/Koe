import Foundation
import Observation

/// 議事録の Google Docs アップロードキュー。JSON でディスク永続化し、
/// アプリのフォアグラウンド復帰と保存直後に drain する（オフライン時のリトライ担保）。
@MainActor
@Observable
final class UploadQueue {
    static let shared = UploadQueue()

    enum Status {
        case none       // 対象外（サインイン前に保存されたものなど）
        case pending    // キュー内・未アップロード
        case failed     // 直近の試行が失敗（キューには残る）
        case uploaded   // アップロード済み
    }

    struct Item: Codable {
        let fileName: String
        var attempts: Int = 0
        var lastError: String?
    }

    private(set) var items: [Item] = []
    private(set) var uploadedNames: Set<String> = []
    private var isDraining = false

    private static let queueFile: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("upload-queue.json")
    private static let uploadedKey = "uploadedMeetingFiles"

    private init() {
        if let data = try? Data(contentsOf: Self.queueFile),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        uploadedNames = Set(UserDefaults.standard.stringArray(forKey: Self.uploadedKey) ?? [])
    }

    func status(for url: URL) -> Status {
        let name = url.lastPathComponent
        if uploadedNames.contains(name) { return .uploaded }
        if let item = items.first(where: { $0.fileName == name }) {
            return item.lastError == nil ? .pending : .failed
        }
        return .none
    }

    func enqueue(_ url: URL) {
        let name = url.lastPathComponent
        guard !uploadedNames.contains(name),
              !items.contains(where: { $0.fileName == name }) else { return }
        items.append(Item(fileName: name))
        persist()
    }

    /// キューを順に処理する。未サインインなら何もしない（サインイン後の drain で回収）。
    func drain() async {
        guard GoogleOAuthClient.shared.isSignedIn, !isDraining, !items.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }

        let uploader = DriveUploader()
        for index in items.indices.reversed() {
            let item = items[index]
            let url = MeetingSession.meetingsDir.appendingPathComponent(item.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                items.remove(at: index)  // 元ファイルが削除済みなら諦める
                continue
            }
            do {
                _ = try await uploader.upload(fileURL: url)
                items.remove(at: index)
                uploadedNames.insert(item.fileName)
            } catch {
                items[index].attempts += 1
                items[index].lastError = error.localizedDescription
            }
        }
        persist()
        UserDefaults.standard.set(Array(uploadedNames), forKey: Self.uploadedKey)
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: Self.queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.queueFile, options: .atomic)
        }
    }
}
