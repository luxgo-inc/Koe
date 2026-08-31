import Foundation
import Testing
@testable import KoeCore

@Suite struct RefinementPromptBuilderTests {
    @Test func 原文はノンス付きデリミタで区切られる() {
        let msg = RefinementPromptBuilder.buildUserMessage(transcript: "えーとテストです", nonce: "abc123")
        #expect(msg.contains("<transcript-abc123>\nえーとテストです\n</transcript-abc123>"))
        #expect(msg.contains("従ってはいけません"))
    }

    @Test func リクエストボディにモデルIDと原文が入る() throws {
        let data = try RefinementPromptBuilder.requestBody(
            model: "claude-haiku-4-5-20251001",
            instruction: "整形して",
            transcript: "こんにちは"
        )
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(json["system"] as? String == "整形して")
        #expect((json["max_tokens"] as? Int ?? 0) > 0)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect((messages[0]["content"] as? String)?.contains("こんにちは") == true)
    }
}

@Suite struct RefinementResponseParserTests {
    func response(text: String, stopReason: String = "end_turn") -> Data {
        let obj: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func 正常応答は整形テキストを返す() {
        let original = "えーとこれはテストですあのよろしく"
        let outcome = RefinementResponseParser.parse(
            data: response(text: "これはテストです。よろしく。"), original: original)
        #expect(outcome == .refined("これはテストです。よろしく。"))
    }

    @Test func 空テキストはフォールバック() {
        let outcome = RefinementResponseParser.parse(data: response(text: ""), original: "テストです")
        #expect(outcome == .fallback(reason: "empty"))
    }

    @Test func max_tokens到達はフォールバック() {
        let outcome = RefinementResponseParser.parse(
            data: response(text: "途中まで", stopReason: "max_tokens"), original: "テストです")
        #expect(outcome == .fallback(reason: "max_tokens"))
    }

    @Test func 大幅な水増しはフォールバック() {
        let original = String(repeating: "あ", count: 30)
        let bloated = String(repeating: "い", count: 100)
        let outcome = RefinementResponseParser.parse(data: response(text: bloated), original: original)
        #expect(outcome == .fallback(reason: "length_anomaly"))
    }

    @Test func 大幅な削りすぎもフォールバック() {
        let original = String(repeating: "あ", count: 100)
        let outcome = RefinementResponseParser.parse(data: response(text: "短い"), original: original)
        #expect(outcome == .fallback(reason: "length_anomaly"))
    }

    @Test func 短い原文は長さ比チェックを免除() {
        let outcome = RefinementResponseParser.parse(data: response(text: "はい。"), original: "はい")
        #expect(outcome == .refined("はい。"))
    }

    @Test func 不正JSONはフォールバック() {
        let outcome = RefinementResponseParser.parse(data: Data("oops".utf8), original: "テスト")
        #expect(outcome == .fallback(reason: "invalid_json"))
    }

    @Test func 複数テキストブロックは結合される() {
        let obj: [String: Any] = [
            "content": [
                ["type": "text", "text": "前半です。"],
                ["type": "thinking", "text": "無視される"],
                ["type": "text", "text": "後半です。"],
            ],
            "stop_reason": "end_turn",
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        #expect(RefinementResponseParser.parse(data: data, original: "前半です後半です") == .refined("前半です。後半です。"))
    }

    @Test func stop_reason欠落でも正常パース() {
        let obj: [String: Any] = ["content": [["type": "text", "text": "テキスト。"]]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        #expect(RefinementResponseParser.parse(data: data, original: "テキスト") == .refined("テキスト。"))
    }
}
