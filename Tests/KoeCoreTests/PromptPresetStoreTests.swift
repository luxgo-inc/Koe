import Foundation
import Testing
@testable import KoeCore

@Suite struct PromptPresetStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-presets-\(UUID().uuidString).json")
    }

    @Test func 初回ロードはデフォルトプリセット1件() {
        let store = PromptPresetStore.load(from: tempURL(), legacyCustomInstruction: nil, storedSelectedID: nil)
        #expect(store.presets.count == 1)
        #expect(store.presets[0].name == "AIエージェント用")
        #expect(store.presets[0].instruction == RefinementPromptBuilder.defaultInstruction)
        #expect(store.selected.id == store.presets[0].id)
    }

    @Test func 旧カスタム設定はカスタムプリセットとして取り込まれ選択される() {
        let store = PromptPresetStore.load(from: tempURL(), legacyCustomInstruction: "俺のプロンプト", storedSelectedID: nil)
        #expect(store.presets.count == 2)
        #expect(store.presets[1].name == "カスタム")
        #expect(store.presets[1].instruction == "俺のプロンプト")
        #expect(store.selected.instruction == "俺のプロンプト")
    }

    @Test func デフォルトと同一の旧設定は取り込まない() {
        let store = PromptPresetStore.load(
            from: tempURL(),
            legacyCustomInstruction: RefinementPromptBuilder.defaultInstruction,
            storedSelectedID: nil)
        #expect(store.presets.count == 1)
    }

    @Test func 保存して読み戻すと選択も復元される() throws {
        let url = tempURL()
        var store = PromptPresetStore.load(from: url, legacyCustomInstruction: nil, storedSelectedID: nil)
        let added = store.add(name: "メール用", instruction: "丁寧語に整える")
        store.selectedID = added.id
        try store.save(to: url)
        let reloaded = PromptPresetStore.load(
            from: url, legacyCustomInstruction: nil, storedSelectedID: added.id.uuidString)
        #expect(reloaded.presets.count == 2)
        #expect(reloaded.selected.name == "メール用")
    }

    @Test func 選択IDが不正なら先頭にフォールバック() throws {
        let url = tempURL()
        let store = PromptPresetStore.load(from: url, legacyCustomInstruction: nil, storedSelectedID: nil)
        try store.save(to: url)
        let reloaded = PromptPresetStore.load(
            from: url, legacyCustomInstruction: nil, storedSelectedID: UUID().uuidString)
        #expect(reloaded.selected.id == reloaded.presets[0].id)
    }

    @Test func 削除で最後の1件は消せない() {
        var store = PromptPresetStore.load(from: tempURL(), legacyCustomInstruction: nil, storedSelectedID: nil)
        store.remove(id: store.presets[0].id)
        #expect(store.presets.count == 1)  // 最後の1件は保持
        let added = store.add(name: "二つ目", instruction: "x")
        store.selectedID = added.id
        store.remove(id: added.id)
        #expect(store.presets.count == 1)
        #expect(store.selected.id == store.presets[0].id)  // 選択が消えたら先頭へ
    }
}
