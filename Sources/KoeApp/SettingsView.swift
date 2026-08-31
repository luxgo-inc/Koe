import KoeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var controller: RecordingController
    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    @State private var instruction: String = AppSettings().refinementInstruction
    @State private var modelID: String = AppSettings().modelID

    var body: some View {
        Form {
            Section("AI整形") {
                Toggle("AI整形を有効にする", isOn: Binding(
                    get: { controller.settings.aiRefinementEnabled },
                    set: { controller.settings.aiRefinementEnabled = $0 }))
                SecureField("Anthropic API キー", text: $apiKey)
                    .onSubmit { KeychainStore.saveAPIKey(apiKey) }
                Button("APIキーを保存") { KeychainStore.saveAPIKey(apiKey) }
                TextField("モデルID", text: $modelID)
                    .onSubmit { controller.settings.modelID = modelID }
                Text("整形プロンプト:")
                TextEditor(text: $instruction)
                    .frame(minHeight: 120)
                    .font(.callout)
                Button("プロンプトを保存") { controller.settings.refinementInstruction = instruction }
            }
            Section("ホットキー") {
                HotkeyCodeField(label: "素のまま録音", code: Binding(
                    get: { controller.settings.rawHotkeyCode },
                    set: { controller.settings.rawHotkeyCode = $0; controller.reloadHotkeys() }))
                HotkeyCodeField(label: "AI整形録音", code: Binding(
                    get: { controller.settings.refinedHotkeyCode },
                    set: { controller.settings.refinedHotkeyCode = $0; controller.reloadHotkeys() }))
                Text("既定: F9=101 / F10=109。キーコードを直接指定する。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("履歴") {
                Toggle("確定テキストをログに残す（平文保存に注意）", isOn: Binding(
                    get: { controller.settings.historyEnabled },
                    set: { controller.settings.historyEnabled = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}

/// キーコードの数値直接入力（YAGNI: キーキャプチャUIは作らない）
struct HotkeyCodeField: View {
    let label: String
    @Binding var code: Int64

    var body: some View {
        HStack {
            Text(label)
            TextField("keycode", value: Binding(
                get: { Int(code) }, set: { code = Int64($0) }), format: .number)
                .frame(width: 80)
        }
    }
}
