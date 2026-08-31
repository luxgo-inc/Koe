public enum RecordingMode: String, Sendable, Equatable {
    case raw, refined
}

/// 録音操作の純粋ステートマシン。時刻は外から渡す（テスト容易性のため）。
/// key repeat は呼び出し側（HotkeyMonitor）で除外してから渡すこと。
public struct RecordingStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// keyDownAt が non-nil = キーがまだ押されている（PTT候補）
        case recording(mode: RecordingMode, keyDownAt: Double?)
        case finalizing(mode: RecordingMode)
        case refining
        case inserting
    }

    public enum Event: Equatable, Sendable {
        case keyDown(mode: RecordingMode, at: Double)
        case keyUp(mode: RecordingMode, at: Double)
        case escape
        /// refine は mode == .refined から導出しない: AI整形がグローバルOFF・APIキー未設定の場合、
        /// F10（refinedモード）でも素のまま挿入するため、呼び出し側（RecordingController）が
        /// 設定を加味して決定する。
        case transcriptReady(refine: Bool)
        case refinementFinished
        case insertionFinished
        case failure
        case maxDurationReached
    }

    public enum Action: Equatable, Sendable {
        case startCapture(mode: RecordingMode)
        case stopAndFinalize
        case cancel
        case beginRefining
        case beginInserting
        case insertRawInstead
        case none
    }

    public private(set) var state: State = .idle
    public let holdThreshold: Double

    public init(holdThreshold: Double = 0.4) {
        self.holdThreshold = holdThreshold
    }

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        // --- idle ---
        case (.idle, .keyDown(let mode, let t)):
            state = .recording(mode: mode, keyDownAt: t)
            return .startCapture(mode: mode)
        case (.idle, _):
            return .none

        // --- recording ---
        case (.recording(let mode, .some(let downAt)), .keyUp(let upMode, let t)) where upMode == mode:
            if t - downAt >= holdThreshold {
                state = .finalizing(mode: mode)
                return .stopAndFinalize
            } else {
                state = .recording(mode: mode, keyDownAt: nil)
                return .none
            }
        case (.recording(let mode, .none), .keyDown(let downMode, _)) where downMode == mode:
            state = .finalizing(mode: mode)
            return .stopAndFinalize
        case (.recording, .keyDown), (.recording, .keyUp):
            return .none  // 反対キー・整合しないUp
        case (.recording, .escape):
            state = .idle
            return .cancel
        case (.recording(let mode, _), .maxDurationReached):
            state = .finalizing(mode: mode)
            return .stopAndFinalize
        case (.recording, .failure):
            state = .idle
            return .cancel
        case (.recording, _):
            return .none

        // --- finalizing ---
        case (.finalizing, .transcriptReady(let refine)):
            if refine {
                state = .refining
                return .beginRefining
            } else {
                state = .inserting
                return .beginInserting
            }
        case (.finalizing, .failure):
            state = .idle
            return .cancel
        case (.finalizing, _):
            return .none

        // --- refining ---
        case (.refining, .refinementFinished):
            state = .inserting
            return .beginInserting
        case (.refining, .escape), (.refining, .failure):
            state = .inserting
            return .insertRawInstead
        case (.refining, _):
            return .none

        // --- inserting ---
        case (.inserting, .insertionFinished), (.inserting, .failure):
            state = .idle
            return .none
        case (.inserting, _):
            return .none
        }
    }
}
