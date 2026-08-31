import KoeCore
import SwiftUI
import UserNotifications

@main
struct KoeApp: App {
    @State private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra("Koe", systemImage: controller.isRecording ? "mic.fill" : "mic") {
            PopoverContent(controller: controller)
                .task {
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert])
                    await controller.startup()
                }
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(controller: controller)
        }
    }
}

struct PopoverContent: View {
    @Bindable var controller: RecordingController
    @State private var copiedIndex: Int?
    @State private var permissionsMissing = false
    @State private var presetStore: PromptPresetStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ヘッダ: モード＋AI整形トグル
            HStack {
                Image(systemName: controller.isRecording ? "mic.fill" : "mic")
                Text(controller.isRecording ? "録音中" : "待機中")
                    .font(.headline)
                Spacer()
                Toggle("AI整形", isOn: Binding(
                    get: { controller.settings.aiRefinementEnabled },
                    set: { controller.settings.aiRefinementEnabled = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            // プリセット切替
            if let store = presetStore, controller.settings.aiRefinementEnabled {
                Picker("プリセット", selection: Binding(
                    get: { store.selected.id },
                    set: { newID in
                        controller.settings.selectedPresetID = newID.uuidString
                        presetStore = controller.loadPresetStore()
                    })) {
                    ForEach(store.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
            }

            // 権限警告バナー
            if permissionsMissing {
                Button {
                    PermissionsWindow.show()
                } label: {
                    Label("権限が不足しています", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            // 直近3件
            if !controller.recentTranscripts.isEmpty {
                Divider()
                Text("直近の書き起こし").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(controller.recentTranscripts.enumerated()), id: \.offset) { index, text in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copiedIndex = index
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            if copiedIndex == index { copiedIndex = nil }
                        }
                    } label: {
                        HStack {
                            Text(text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copiedIndex == index ? .green : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // フッタ
            HStack {
                Button("履歴…") { HistoryWindow.show() }
                Spacer()
                SettingsLink { Text("設定…") }
            }
            HStack {
                Button("音声モデル再DL") { controller.retryModelDownload() }
                Spacer()
                Button("アップデート確認") { UpdateChecker.check() }
            }
            Button("Koe を終了") { NSApplication.shared.terminate(nil) }
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            presetStore = controller.loadPresetStore()
            permissionsMissing = !(CGPreflightListenEventAccess() && CGPreflightPostEventAccess())
        }
    }
}
