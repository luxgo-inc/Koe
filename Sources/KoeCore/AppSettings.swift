import Foundation

/// UserDefaults 直読み書きの設定。GUI からは @Observable な ViewModel 経由で使う。
public struct AppSettings: Sendable {
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var aiRefinementEnabled: Bool {
        get { defaults.bool(forKey: "aiRefinementEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "aiRefinementEnabled") }
    }

    public var historyEnabled: Bool {
        get { defaults.bool(forKey: "historyEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "historyEnabled") }
    }

    public var modelID: String {
        get { defaults.string(forKey: "modelID") ?? "claude-haiku-4-5-20251001" }
        nonmutating set { defaults.set(newValue, forKey: "modelID") }
    }

    public var refinementInstruction: String {
        get { defaults.string(forKey: "refinementInstruction") ?? RefinementPromptBuilder.defaultInstruction }
        nonmutating set { defaults.set(newValue, forKey: "refinementInstruction") }
    }

    public var rawHotkeyCode: Int64 {
        get { defaults.object(forKey: "rawHotkeyCode") == nil ? 101 : Int64(defaults.integer(forKey: "rawHotkeyCode")) }
        nonmutating set { defaults.set(Int(newValue), forKey: "rawHotkeyCode") }
    }

    public var refinedHotkeyCode: Int64 {
        get { defaults.object(forKey: "refinedHotkeyCode") == nil ? 109 : Int64(defaults.integer(forKey: "refinedHotkeyCode")) }
        nonmutating set { defaults.set(Int(newValue), forKey: "refinedHotkeyCode") }
    }
}
