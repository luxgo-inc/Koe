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
        get { defaults.object(forKey: "historyEnabled") == nil ? true : defaults.bool(forKey: "historyEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "historyEnabled") }
    }

    /// 会議録音の話者分離（デフォルトON）。iOS 版の「話者分離」トグルと同じキーを共有する。
    public var diarizationEnabled: Bool {
        get { defaults.object(forKey: "diarizationEnabled") == nil ? true : defaults.bool(forKey: "diarizationEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "diarizationEnabled") }
    }

    public var modelID: String {
        get { defaults.string(forKey: "modelID") ?? "claude-haiku-4-5-20251001" }
        nonmutating set { defaults.set(newValue, forKey: "modelID") }
    }

    public var legacyRefinementInstruction: String? {
        defaults.string(forKey: "refinementInstruction")
    }

    public var rawHotkeyCode: Int64 {
        get { defaults.object(forKey: "rawHotkeyCode") == nil ? 101 : Int64(defaults.integer(forKey: "rawHotkeyCode")) }
        nonmutating set { defaults.set(Int(newValue), forKey: "rawHotkeyCode") }
    }

    public var refinedHotkeyCode: Int64 {
        get { defaults.object(forKey: "refinedHotkeyCode") == nil ? 109 : Int64(defaults.integer(forKey: "refinedHotkeyCode")) }
        nonmutating set { defaults.set(Int(newValue), forKey: "refinedHotkeyCode") }
    }

    /// 録音に使う入力マイクの UID（nil = システムのデフォルト入力に従う）。
    /// 固定したマイクが未接続のときはデフォルト入力にフォールバックする。
    public var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: "inputDeviceUID")
            } else {
                defaults.removeObject(forKey: "inputDeviceUID")
            }
        }
    }

    public static let defaultRecognitionHints = [
        "E-Space", "LUXGO", "Koe", "Claude", "ChatGPT", "GitHub", "Firebase",
        "台東区", "産業フェア",
    ]

    /// 用語リスト（固有名詞・専門用語の正しい表記）。AI整形のプロンプトと音声認識のヒントに使う。
    /// 未設定なら既定のリスト。
    public var recognitionHints: [String] {
        get { defaults.stringArray(forKey: "recognitionHints") ?? Self.defaultRecognitionHints }
        nonmutating set { defaults.set(newValue, forKey: "recognitionHints") }
    }

    /// 異常終了（クラッシュ・メモリ枯渇による kill）時に自動で再起動する（デフォルトON）。
    public var autoRestartEnabled: Bool {
        get { defaults.object(forKey: "autoRestartEnabled") == nil ? true : defaults.bool(forKey: "autoRestartEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "autoRestartEnabled") }
    }

    public var selectedPresetID: String? {
        get { defaults.string(forKey: "selectedPresetID") }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: "selectedPresetID")
            } else {
                defaults.removeObject(forKey: "selectedPresetID")
            }
        }
    }
}
