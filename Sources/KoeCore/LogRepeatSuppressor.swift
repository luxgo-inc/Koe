import Foundation

/// 同じログ行が連続したとき、2回目以降を書かずに件数だけ数えておく。
/// 何かが暴走して同じ行を毎秒数十回出すと、ローテーションで
/// 「暴走が始まったきっかけ」の行が押し流されて消えるのを防ぐ。
/// 別の行が来たとき、または同じ行が続いたまま `summaryInterval` 秒経ったときに、
/// 「直前の行が N 回繰り返された」という要約を1行だけ出す。
public struct LogRepeatSuppressor: Sendable {
    public enum Output: Equatable, Sendable {
        /// そのまま書く行
        case line(String)
        /// 直前の行が（書いた1回に加えて）さらに count 回繰り返された
        case repeated(count: Int)
    }

    public let summaryInterval: TimeInterval
    private var lastKey: String?
    private var suppressed = 0
    private var lastEmittedAt: TimeInterval = 0

    public init(summaryInterval: TimeInterval = 60) {
        self.summaryInterval = summaryInterval
    }

    /// key は「同じ行か」の判定に使う（レベル＋本文など。時刻は含めない）。
    public mutating func process(_ key: String, at now: TimeInterval) -> [Output] {
        if key == lastKey {
            suppressed += 1
            guard now - lastEmittedAt >= summaryInterval else { return [] }
            let count = suppressed
            suppressed = 0
            lastEmittedAt = now
            return [.repeated(count: count)]
        }
        var outputs: [Output] = []
        if suppressed > 0 { outputs.append(.repeated(count: suppressed)) }
        outputs.append(.line(key))
        lastKey = key
        suppressed = 0
        lastEmittedAt = now
        return outputs
    }
}
