import KoeCore
import Testing

struct EventRateLimiterTests {
    /// 時刻の列を順に allow() し、結果の列を返す（#expect の中では mutating を呼べないため）。
    private func run(_ limiter: inout EventRateLimiter, _ times: [Double]) -> [Bool] {
        times.map { limiter.allow(at: $0) }
    }

    @Test func 上限まで許可してそれ以上は拒否する() {
        var limiter = EventRateLimiter(maxEvents: 3, window: 10)
        let results = run(&limiter, [0, 1, 2, 3, 9.9])
        #expect(results == [true, true, true, false, false])
    }

    @Test func 窓を過ぎた分は数えない() {
        var limiter = EventRateLimiter(maxEvents: 2, window: 10)
        // 10 秒の時点で 0 秒の分が窓から外れるので1回空く
        let results = run(&limiter, [0, 5, 9, 10, 11])
        #expect(results == [true, true, false, true, false])
    }

    @Test func 拒否した回は記録しない() {
        var limiter = EventRateLimiter(maxEvents: 1, window: 10)
        // 連続して拒否されても窓が延長されない
        let results = run(&limiter, [0, 1, 3, 5, 7, 9, 10])
        #expect(results == [true, false, false, false, false, false, true])
    }

    @Test func resetで履歴を消す() {
        var limiter = EventRateLimiter(maxEvents: 1, window: 10)
        let first = run(&limiter, [0])
        limiter.reset()
        let second = run(&limiter, [1])
        #expect(first == [true])
        #expect(second == [true])
    }
}
