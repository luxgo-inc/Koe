import Foundation

/// 直近 `window` 秒の間に `maxEvents` 回までだけ許可する（スライディングウィンドウ）。
/// オーディオデバイスの構成変更のように、自分の処理が次の通知を呼び込んで
/// 自己増殖し得る処理のサーキットブレーカーに使う。時刻は呼び出し側が渡す
/// （単調増加の秒。ProcessInfo.systemUptime など）。
public struct EventRateLimiter: Sendable {
    public let maxEvents: Int
    public let window: TimeInterval
    private var timestamps: [TimeInterval] = []

    public init(maxEvents: Int, window: TimeInterval) {
        self.maxEvents = maxEvents
        self.window = window
    }

    /// 許可できるなら記録して true。上限に達していれば記録せず false。
    public mutating func allow(at now: TimeInterval) -> Bool {
        timestamps.removeAll { now - $0 >= window }
        guard timestamps.count < maxEvents else { return false }
        timestamps.append(now)
        return true
    }

    public mutating func reset() {
        timestamps.removeAll()
    }
}
