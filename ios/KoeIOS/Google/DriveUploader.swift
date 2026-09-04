import Foundation

/// Google Drive への議事録アップロード。Markdown を multipart/related で送り、
/// mimeType application/vnd.google-apps.document 指定で Google ドキュメントに変換させる
/// （Drive API は Markdown → Docs 変換をネイティブサポート。見出し・箇条書きが保持される）。
/// アップロード先は「Koe」フォルダ（無ければ作成、drive.file スコープ内で自アプリ作成分のみ可視）。
@MainActor
struct DriveUploader {
    private static let folderIDKey = "googleKoeFolderID"

    enum UploadError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case .http(let code, let body) = self {
                return "Drive API エラー (HTTP \(code)): \(body.prefix(200))"
            }
            return nil
        }
    }

    /// アップロードして作成された Google ドキュメントの fileId を返す。
    func upload(fileURL: URL) async throws -> String {
        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let token = try await GoogleOAuthClient.shared.accessToken()
        do {
            let folderID = try await ensureKoeFolder(token: token)
            return try await performUpload(markdown: markdown, name: name, folderID: folderID, token: token)
        } catch UploadError.http(404, _) {
            // キャッシュ済みフォルダが削除されていた場合は作り直して1回だけ再試行
            UserDefaults.standard.removeObject(forKey: Self.folderIDKey)
            let folderID = try await ensureKoeFolder(token: token)
            return try await performUpload(markdown: markdown, name: name, folderID: folderID, token: token)
        }
    }

    private func performUpload(
        markdown: String, name: String, folderID: String, token: String
    ) async throws -> String {
        let boundary = "koe-boundary-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.document",
            "parents": [folderID],
        ]
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/markdown; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(markdown.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(
            string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let json = try await Self.send(req)
        return json["id"] as? String ?? ""
    }

    private func ensureKoeFolder(token: String) async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: Self.folderIDKey) {
            return cached
        }
        // 既存の「Koe」フォルダを検索（drive.file スコープでは自アプリ作成分のみヒット）
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(
                name: "q",
                value: "name = 'Koe' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id)"),
        ]
        var searchReq = URLRequest(url: comps.url!)
        searchReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let searchJSON = try await Self.send(searchReq)
        if let files = searchJSON["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            UserDefaults.standard.set(id, forKey: Self.folderIDKey)
            return id
        }
        // 無ければ作成
        var createReq = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "Koe",
            "mimeType": "application/vnd.google-apps.folder",
        ])
        let createJSON = try await Self.send(createReq)
        guard let id = createJSON["id"] as? String else {
            throw UploadError.http(-1, "フォルダ作成応答に id がありません")
        }
        UserDefaults.standard.set(id, forKey: Self.folderIDKey)
        return id
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UploadError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
