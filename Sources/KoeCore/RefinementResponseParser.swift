import Foundation

public enum RefinementOutcome: Equatable, Sendable {
    case refined(String)
    case fallback(reason: String)
}

public enum RefinementResponseParser {
    /// Claude Messages API のレスポンスを検証つきでパースする。
    /// 異常（空・max_tokens・大幅改変・不正JSON）はすべて fallback を返し、
    /// 呼び出し側は原文を挿入する。
    public static func parse(data: Data, original: String) -> RefinementOutcome {
        struct Response: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]
            let stop_reason: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return .fallback(reason: "invalid_json")
        }
        if response.stop_reason == "max_tokens" {
            return .fallback(reason: "max_tokens")
        }
        let text = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .fallback(reason: "empty")
        }
        // 原文が一定長以上のとき、3倍超 or 1/3未満は「大幅改変」としてフォールバック
        if original.count > 20 {
            let ratio = Double(text.count) / Double(original.count)
            if ratio > 3.0 || ratio < 1.0 / 3.0 {
                return .fallback(reason: "length_anomaly")
            }
        }
        return .refined(text)
    }
}
