import AppKit
import KoeCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var controller: RecordingController
    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    @State private var modelID: String = AppSettings().modelID
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var rules: [ReplacementRule] = ReplacementDictionary
        .load(from: RecordingController.replacementsURL).rules
    @State private var selectedRuleIndex: Int?
    @State private var presetStore: PromptPresetStore?
    @State private var selectedPresetID: UUID?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("一般", systemImage: "gear") }
            aiTab.tabItem { Label("AI整形", systemImage: "wand.and.stars") }
            replacementTab.tabItem { Label("置換辞書", systemImage: "arrow.left.arrow.right") }
        }
        .frame(width: 560, height: 500)
        .onAppear {
            presetStore = controller.loadPresetStore()
            selectedPresetID = presetStore?.selectedID
        }
    }

    // MARK: - 一般タブ

    private var generalTab: some View {
        Form {
            Section("ホットキー") {
                KeyCaptureField(
                    label: "素のまま録音",
                    keyCode: Binding(
                        get: { controller.settings.rawHotkeyCode },
                        set: { controller.settings.rawHotkeyCode = $0; controller.reloadHotkeys() }),
                    conflictCode: controller.settings.refinedHotkeyCode)
                KeyCaptureField(
                    label: "AI整形録音",
                    keyCode: Binding(
                        get: { controller.settings.refinedHotkeyCode },
                        set: { controller.settings.refinedHotkeyCode = $0; controller.reloadHotkeys() }),
                    conflictCode: controller.settings.rawHotkeyCode)
                Text("ボタンを押してキーを入力してください。Escで中止、もう一方と同じキーは無効です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("履歴") {
                Toggle("確定テキストをログに残す（平文保存に注意）", isOn: Binding(
                    get: { controller.settings.historyEnabled },
                    set: { controller.settings.historyEnabled = $0 }))
            }
            Section("起動") {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }))
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: - AI整形タブ

    private var aiTab: some View {
        Form {
            Section("AI整形") {
                Toggle("AI整形を有効にする", isOn: Binding(
                    get: { controller.settings.aiRefinementEnabled },
                    set: { controller.settings.aiRefinementEnabled = $0 }))
                SecureField("Anthropic API キー", text: $apiKey)
                    .onSubmit { KeychainStore.saveAPIKey(apiKey) }
                Button("APIキーを保存") { KeychainStore.saveAPIKey(apiKey) }
                TextField("モデルID", text: $modelID)
                    .onSubmit {
                        controller.settings.modelID = modelID
                    }
            }
            Section("プリセット") {
                if let store = presetStore {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading) {
                            List(store.presets, selection: $selectedPresetID) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                            .frame(width: 160, height: 200)
                            HStack {
                                Button("追加") { addPreset() }
                                Button("削除") { removeSelectedPreset() }
                                    .disabled(store.presets.count <= 1 || selectedPresetID == nil)
                            }
                        }
                        if let selectedID = selectedPresetID,
                           let index = store.presets.firstIndex(where: { $0.id == selectedID }) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("名前", text: Binding(
                                    get: { presetStore?.presets[index].name ?? "" },
                                    set: { newValue in
                                        updatePreset(id: selectedID) { $0.name = newValue }
                                    }))
                                Text("本文")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: Binding(
                                    get: { presetStore?.presets[index].instruction ?? "" },
                                    set: { newValue in
                                        updatePreset(id: selectedID) { $0.instruction = newValue }
                                    }))
                                    .frame(minHeight: 140)
                                    .border(Color.gray.opacity(0.3))
                            }
                        } else {
                            Text("プリセットを選択してください")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("使用中プリセット", selection: Binding(
                        get: { controller.settings.selectedPresetID.flatMap(UUID.init(uuidString:)) ?? store.selectedID },
                        set: { newValue in
                            controller.settings.selectedPresetID = newValue.uuidString
                            presetStore?.selectedID = newValue
                        })) {
                        ForEach(store.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addPreset() {
        guard var store = presetStore else { return }
        let new = store.add(name: "新しいプリセット", instruction: "")
        presetStore = store
        selectedPresetID = new.id
        try? store.save(to: RecordingController.presetsURL)
    }

    private func removeSelectedPreset() {
        guard var store = presetStore, let id = selectedPresetID else { return }
        store.remove(id: id)
        presetStore = store
        selectedPresetID = store.selectedID
        try? store.save(to: RecordingController.presetsURL)
    }

    private func updatePreset(id: UUID, mutate: (inout PromptPreset) -> Void) {
        guard var store = presetStore,
              var preset = store.presets.first(where: { $0.id == id }) else { return }
        mutate(&preset)
        store.update(preset)
        presetStore = store
        try? store.save(to: RecordingController.presetsURL)
    }

    // MARK: - 置換辞書タブ

    private var replacementTab: some View {
        Form {
            Section("置換辞書") {
                Text("from が空の行は無視されます")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selectedRuleIndex) {
                    ForEach(rules.indices, id: \.self) { index in
                        HStack {
                            TextField("置換前", text: Binding(
                                get: { rules[index].from },
                                set: { rules[index].from = $0; saveRules() }))
                            Image(systemName: "arrow.right")
                            TextField("置換後", text: Binding(
                                get: { rules[index].to },
                                set: { rules[index].to = $0; saveRules() }))
                            Button {
                                removeRule(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .tag(index)
                    }
                }
                .frame(minHeight: 220)
                HStack {
                    Button("追加") { addRule() }
                    Button("上へ") { moveSelected(offset: -1) }
                        .disabled(!canMoveSelected(offset: -1))
                    Button("下へ") { moveSelected(offset: 1) }
                        .disabled(!canMoveSelected(offset: 1))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addRule() {
        rules.append(ReplacementRule(from: "", to: ""))
        selectedRuleIndex = rules.count - 1
        saveRules()
    }

    private func removeRule(at index: Int) {
        rules.remove(at: index)
        selectedRuleIndex = nil
        saveRules()
    }

    private func canMoveSelected(offset: Int) -> Bool {
        guard let index = selectedRuleIndex else { return false }
        let target = index + offset
        return target >= 0 && target < rules.count
    }

    private func moveSelected(offset: Int) {
        guard let index = selectedRuleIndex else { return }
        let target = index + offset
        guard target >= 0 && target < rules.count else { return }
        rules.swapAt(index, target)
        selectedRuleIndex = target
        saveRules()
    }

    private func saveRules() {
        try? ReplacementDictionary(rules: rules).save(to: RecordingController.replacementsURL)
    }
}

/// ホットキーのキャプチャUI。ボタンを押すとキー入力を待ち受け、押されたキーを反映する。
struct KeyCaptureField: View {
    let label: String
    @Binding var keyCode: Int64
    let conflictCode: Int64
    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(capturing ? "キーを押してください…（Escで中止）" : keyName(keyCode)) {
                startCapture()
            }
            .buttonStyle(.bordered)
        }
    }

    private func startCapture() {
        guard !capturing else { return }
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopCapture() }
            let code = Int64(event.keyCode)
            if code == 53 { return nil }           // Esc = キャンセル
            if code == conflictCode {
                NSSound.beep()                      // 衝突は拒否
                return nil
            }
            keyCode = code
            return nil
        }
    }

    private func stopCapture() {
        capturing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func keyName(_ code: Int64) -> String {
        let names: [Int64: String] = [
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            49: "Space", 36: "Return", 48: "Tab",
        ]
        return names[code] ?? "key \(code)"
    }
}
