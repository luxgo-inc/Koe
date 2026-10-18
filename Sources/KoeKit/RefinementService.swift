import Foundation
import KoeCore

/// Claude Messages API での整形。wall-clock 6秒タイムアウト、全異常系は fallback。
/// 3秒だとイベント会場の Wi-Fi / テザリングで超えやすく、素のまま挿入になりがちだったため延長。
public struct RefinementService: Sendable {
    public let timeout: Duration

    public init(timeout: Duration = .seconds(6)) {
        self.timeout = timeout
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    nonisolated(unsafe) private static var lastPreconnect: ContinuousClock.Instant?
    private static let preconnectLock = NSLock()

    /// 録音開始時に呼び、整形リクエストより先に DNS・TCP・TLS を済ませておく。
    /// URLSession.shared は同一ホストの接続を使い回すため、録音の間に張った接続へ
    /// 本リクエストが乗り、整形の待ち時間が数百ms縮む。認証なしの HEAD なので課金はない。
    /// 接続は一定時間生きるため、20秒以内の再呼び出しは何もしない。
    public static func preconnect() {
        let now = ContinuousClock.now
        let shouldSend = preconnectLock.withLock {
            if let last = lastPreconnect, now - last < .seconds(20) { return false }
            lastPreconnect = now
            return true
        }
        guard shouldSend else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// 常に挿入すべきテキストを返す（整形失敗時は原文）。
    /// 第2戻り値はフォールバック理由（正常時 nil、通知表示用）。
    /// glossary: 正しい表記に寄せたい固有名詞（設定の用語リスト）。
    public func refine(
        _ transcript: String, modelID: String, instruction: String, glossary: [String] = []
    ) async -> (String, String?) {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            return (transcript, "api_key_missing")
        }
        do {
            let outcome = try await withThrowingTaskGroup(of: RefinementOutcome.self) { group in
                group.addTask {
                    try await request(
                        transcript: transcript, apiKey: apiKey, modelID: modelID,
                        instruction: instruction, glossary: glossary)
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
        transcript: String, apiKey: String, modelID: String, instruction: String, glossary: [String]
    ) async throws -> RefinementOutcome {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try RefinementPromptBuilder.requestBody(
            model: modelID,
            instruction: instruction,
            transcript: transcript,
            glossary: glossary
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return .fallback(reason: "http_error")
        }
        return RefinementResponseParser.parse(data: data, original: transcript)
    }
}
