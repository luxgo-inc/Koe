import Testing
@testable import KoeCore

@Suite struct RecordingStateMachineTests {
    func machine() -> RecordingStateMachine { RecordingStateMachine(holdThreshold: 0.4) }

    @Test func idleでkeyDownすると録音開始() {
        var m = machine()
        let action = m.handle(.keyDown(mode: .raw, at: 100.0))
        #expect(action == .startCapture(mode: .raw))
        #expect(m.state == .recording(mode: .raw, keyDownAt: 100.0))
    }

    @Test func 短いタップは録音継続_2回目のタップで確定() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        #expect(m.handle(.keyUp(mode: .raw, at: 100.2)) == .none)
        #expect(m.state == .recording(mode: .raw, keyDownAt: nil))
        #expect(m.handle(.keyDown(mode: .raw, at: 103.0)) == .stopAndFinalize)
        #expect(m.state == .finalizing(mode: .raw))
        #expect(m.handle(.keyUp(mode: .raw, at: 103.1)) == .none)
    }

    @Test func ホールドはkeyUpで確定() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .refined, at: 100.0))
        #expect(m.handle(.keyUp(mode: .refined, at: 101.5)) == .stopAndFinalize)
        #expect(m.state == .finalizing(mode: .refined))
    }

    @Test func 録音中の反対キーは無視() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        #expect(m.handle(.keyDown(mode: .refined, at: 100.5)) == .none)
        #expect(m.handle(.keyUp(mode: .refined, at: 100.6)) == .none)
        #expect(m.state == .recording(mode: .raw, keyDownAt: 100.0))
    }

    @Test func Escで録音キャンセル() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        #expect(m.handle(.escape) == .cancel)
        #expect(m.state == .idle)
    }

    @Test func idleのEscは何もしない() {
        var m = machine()
        #expect(m.handle(.escape) == .none)
    }

    @Test func 確定処理中のキー押下は無視() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        _ = m.handle(.keyUp(mode: .raw, at: 101.0))
        #expect(m.handle(.keyDown(mode: .raw, at: 101.1)) == .none)
        #expect(m.handle(.keyDown(mode: .refined, at: 101.2)) == .none)
    }

    @Test func rawモードは確定後そのまま挿入() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        _ = m.handle(.keyUp(mode: .raw, at: 101.0))
        #expect(m.handle(.transcriptReady(refine: false)) == .beginInserting)
        #expect(m.state == .inserting)
        #expect(m.handle(.insertionFinished) == .none)
        #expect(m.state == .idle)
    }

    @Test func refinedモードは整形を挟む() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .refined, at: 100.0))
        _ = m.handle(.keyUp(mode: .refined, at: 101.0))
        #expect(m.handle(.transcriptReady(refine: true)) == .beginRefining)
        #expect(m.state == .refining)
        #expect(m.handle(.refinementFinished) == .beginInserting)
        #expect(m.state == .inserting)
    }

    @Test func 整形中のEscは原文挿入へフォールバック() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .refined, at: 100.0))
        _ = m.handle(.keyUp(mode: .refined, at: 101.0))
        _ = m.handle(.transcriptReady(refine: true))
        #expect(m.handle(.escape) == .insertRawInstead)
        #expect(m.state == .inserting)
    }

    @Test func 整形失敗も原文挿入へフォールバック() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .refined, at: 100.0))
        _ = m.handle(.keyUp(mode: .refined, at: 101.0))
        _ = m.handle(.transcriptReady(refine: true))
        #expect(m.handle(.failure) == .insertRawInstead)
        #expect(m.state == .inserting)
    }

    @Test func 空の認識結果はキャンセル扱い() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        _ = m.handle(.keyUp(mode: .raw, at: 101.0))
        #expect(m.handle(.failure) == .cancel)
        #expect(m.state == .idle)
    }

    @Test func 最大録音時間で自動確定() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        _ = m.handle(.keyUp(mode: .raw, at: 100.2))
        #expect(m.handle(.maxDurationReached) == .stopAndFinalize)
        #expect(m.state == .finalizing(mode: .raw))
    }

    @Test func 録音中の失敗はキャンセル() {
        var m = machine()
        _ = m.handle(.keyDown(mode: .raw, at: 100.0))
        #expect(m.handle(.failure) == .cancel)
        #expect(m.state == .idle)
    }
}
