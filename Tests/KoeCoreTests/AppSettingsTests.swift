import Foundation
import Testing
@testable import KoeCore

@Suite struct AppSettingsTests {
    func freshDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func デフォルト値() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.aiRefinementEnabled == false)
        #expect(s.historyEnabled == true)
        #expect(s.modelID == "claude-haiku-4-5-20251001")
        #expect(s.rawHotkeyCode == 101)      // F9
        #expect(s.refinedHotkeyCode == 109)  // F10
        #expect(s.selectedPresetID == nil)
    }

    @Test func 保存した値が読み戻せる() {
        let defaults = freshDefaults()
        var s = AppSettings(defaults: defaults)
        s.aiRefinementEnabled = true
        s.modelID = "claude-sonnet-5"
        s.rawHotkeyCode = 96
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiRefinementEnabled == true)
        #expect(reloaded.modelID == "claude-sonnet-5")
        #expect(reloaded.rawHotkeyCode == 96)
    }

    @Test func selectedPresetIDが保存される() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        let id = UUID().uuidString
        s.selectedPresetID = id
        #expect(AppSettings(defaults: defaults).selectedPresetID == id)
    }

    @Test func historyEnabledは明示OFFにできる() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        #expect(s.historyEnabled == true)   // デフォルトON
        s.historyEnabled = false
        #expect(AppSettings(defaults: defaults).historyEnabled == false)
    }
}
