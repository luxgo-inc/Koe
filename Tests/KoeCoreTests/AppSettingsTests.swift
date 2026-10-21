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
        #expect(s.inputDeviceUID == nil)
        #expect(s.recognitionHints == AppSettings.defaultRecognitionHints)
        #expect(s.autoRestartEnabled == true)
        #expect(s.referenceHotkeyCode == 103)  // F11
        #expect(s.referenceRecordingsDirectory == AppSettings.defaultReferenceRecordingsDirectory)
        #expect(s.referenceRecordingsDirectory.path.hasSuffix("/Koe/Recordings"))
        #expect(s.referenceTrimSilence == true)
        #expect(s.referenceDelivery == .insert)
        #expect(s.lastReferenceRecordingPath == nil)
    }

    @Test func 参考音声の設定を保存し読み戻せる() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        s.referenceHotkeyCode = 111
        s.referenceRecordingsDirectory = URL(fileURLWithPath: "/tmp/ref", isDirectory: true)
        s.referenceTrimSilence = false
        s.referenceDelivery = .clipboardOnly
        s.lastReferenceRecordingPath = "/tmp/ref/a.wav"
        let r = AppSettings(defaults: defaults)
        #expect(r.referenceHotkeyCode == 111)
        #expect(r.referenceRecordingsDirectory.path == "/tmp/ref")
        #expect(r.referenceTrimSilence == false)
        #expect(r.referenceDelivery == .clipboardOnly)
        #expect(r.lastReferenceRecordingPath == "/tmp/ref/a.wav")
        s.lastReferenceRecordingPath = nil
        #expect(AppSettings(defaults: defaults).lastReferenceRecordingPath == nil)
    }

    @Test func 保存先に不正な値が入っていても既定に戻る() {
        let defaults = freshDefaults()
        defaults.set("", forKey: "referenceRecordingsDirectory")
        #expect(AppSettings(defaults: defaults).referenceRecordingsDirectory == AppSettings.defaultReferenceRecordingsDirectory)
        defaults.set("not-a-delivery", forKey: "referenceDelivery")
        #expect(AppSettings(defaults: defaults).referenceDelivery == .insert)
    }

    @Test func 入力マイクとヒント語を保存し解除できる() {
        let s = AppSettings(defaults: freshDefaults())
        s.inputDeviceUID = "BuiltInMicrophoneDevice"
        s.recognitionHints = ["台東区"]
        s.autoRestartEnabled = false
        #expect(s.inputDeviceUID == "BuiltInMicrophoneDevice")
        #expect(s.recognitionHints == ["台東区"])
        #expect(s.autoRestartEnabled == false)
        s.inputDeviceUID = nil
        s.recognitionHints = []
        #expect(s.inputDeviceUID == nil)
        #expect(s.recognitionHints.isEmpty)  // 空にしたら既定に戻らない
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
