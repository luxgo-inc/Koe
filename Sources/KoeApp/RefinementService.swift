import Foundation
import KoeCore

/// Claude Messages API での整形。wall-clock 3秒タイムアウト、全異常系は fallback。
struct RefinementService: Sendable {
    let timeout: Duration

    init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    /// 常に挿入すべきテキストを返す（整形失敗時は原文）。
    /// 第2戻り値はフォールバック理由（正常時 nil、通知表示用）。
    func refine(_ transcript: String, settings: AppSettings) async -> (String, String?) {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            return (transcript, "api_key_missing")
        }
        do {
            let outcome = try await withThrowingTaskGroup(of: RefinementOutcome.self) { group in
                group.addTask {
                    try await request(transcript: transcript, apiKey: apiKey, settings: settings)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            switch outcome {
            case .refined(let text): return (text, nil)
            case .fallback(let reason): return (transcript, reason)
            }
        } catch is CancellationError {
            return (transcript, "timeout")
        } catch {
            return (transcript, "network_error")
        }
    }

    private func request(
        transcript: String, apiKey: String, settings: AppSettings
    ) async throws -> RefinementOutcome {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try RefinementPromptBuilder.requestBody(
            model: settings.modelID,
            instruction: settings.refinementInstruction,
            transcript: transcript
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return .fallback(reason: "http_error")
        }
        return RefinementResponseParser.parse(data: data, original: transcript)
    }
}
