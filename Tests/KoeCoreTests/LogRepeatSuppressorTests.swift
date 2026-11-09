import KoeCore
import Testing

struct LogRepeatSuppressorTests {
    typealias Output = LogRepeatSuppressor.Output

    /// (key, 時刻) の列を順に流し、各回の出力を返す（#expect の中では mutating を呼べないため）。
    private func run(_ s: inout LogRepeatSuppressor, _ inputs: [(String, Double)]) -> [[Output]] {
        inputs.map { s.process($0.0, at: $0.1) }
    }

    @Test func 初回はそのまま書く() {
        var s = LogRepeatSuppressor()
        let out = run(&s, [("a", 0)])
        #expect(out == [[.line("a")]])
    }

    @Test func 連続した同じ行は書かず別の行が来たときに件数を出す() {
        var s = LogRepeatSuppressor()
        let out = run(&s, [("a", 0), ("a", 1), ("a", 2), ("b", 3)])
        #expect(out == [[.line("a")], [], [], [.repeated(count: 2), .line("b")]])
    }

    @Test func 繰り返しが無ければ要約は出さない() {
        var s = LogRepeatSuppressor()
        let out = run(&s, [("a", 0), ("b", 1), ("a", 2)])
        #expect(out == [[.line("a")], [.line("b")], [.line("a")]])
    }

    @Test func 続いている間も一定間隔で件数を出す() {
        var s = LogRepeatSuppressor(summaryInterval: 60)
        let first = run(&s, [("a", 0)] + (1..<60).map { ("a", Double($0)) })
        #expect(first.dropFirst().allSatisfy { $0.isEmpty })
        // 60 秒経った時点で、それまでの 60 回をまとめて出す
        let out = run(&s, [("a", 60), ("a", 61), ("b", 62)])
        // 要約を出した後は数え直す
        #expect(out == [[.repeated(count: 60)], [], [.repeated(count: 1), .line("b")]])
    }
}
