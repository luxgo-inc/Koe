import AppKit
import KoeCore
import KoeKit
import SwiftUI
import UserNotifications

@main
struct KoeApp: App {
    @State private var controller: RecordingController
    @State private var meetingRecorder: MeetingRecorder

    init() {
        let c = RecordingController()
        let m = MeetingRecorder()
        _controller = State(initialValue: c)
        _meetingRecorder = State(initialValue: m)
        // 開発用スモークフック: `KoeApp --meeting-smoke` で20秒の会議録音を自動実行し
        // 保存パスを stdout に出力する（UIを介さず録音→finalize→保存の全経路を検証する用）
        if ProcessInfo.processInfo.arguments.contains("--meeting-smoke") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await m.start()
                if let err = m.errorMessage { print("SMOKE_START_ERROR: \(err)") }
                try? await Task.sleep(for: .seconds(20))
                await m.stopAndSave()
                print("SMOKE_SAVED: \(m.lastSavedURL?.path ?? "NO_FILE") err=\(m.errorMessage ?? "none")")
            }
        }
        // 開発用スモークフック: `KoeApp --input-smoke` で「ホットキー押下〜実際に音が
        // 録れ始めるまで」の内訳を stderr に出す。`KOE_TIMING=1` を併せて指定すると
        // 起動シーケンスの内訳（Timing.mark）も出る。
        if ProcessInfo.processInfo.arguments.contains("--input-smoke") {
            Task { @MainActor in
                // 1回目（デバイス起動あり）／キープアライブ中／キープアライブ切れ後 の3パターン。
                try? await Task.sleep(for: .seconds(6))
                await c.measureStartLatency(label: "1st(cold)")
                try? await Task.sleep(for: .seconds(2))
                await c.measureStartLatency(label: "2nd(keepalive)")
                try? await Task.sleep(for: .seconds(40))  // キープアライブ(30s)切れを待つ
                await c.measureStartLatency(label: "3rd(expired)")
                NSApplication.shared.terminate(nil)
            }
        }
        Timing.mark("App.init")
        // .windowスタイルはコンテンツ生成が初回クリックまで遅延するため、
        // ホットキー監視の起動はApp initで行う（didStartupガードで二重起動なし）
        Task { @MainActor in
            Timing.mark("notif auth: begin")
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
            Timing.mark("notif auth: done")
            await c.startup()
        }
    }

    var body: some Scene {
        MenuBarExtra("Koe", systemImage:
            meetingRecorder.isRecording ? "record.circle.fill"
            : controller.isRecording ? "mic.fill" : "mic") {
            PopoverContent(controller: controller, meetingRecorder: meetingRecorder)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(controller: controller)
        }
    }
}

struct PopoverContent: View {
    @Bindable var controller: RecordingController
    @Bindable var meetingRecorder: MeetingRecorder
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

            Divider()

            // 会議録音（マイク＋システム音声 → 議事録Markdown）
            if meetingRecorder.isRecording {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    if let started = meetingRecorder.startedAt {
                        Text(started, style: .timer).monospacedDigit()
                    }
                    Spacer()
                    Button("停止して保存") {
                        Task { await meetingRecorder.stopAndSave() }
                    }
                }
            } else if meetingRecorder.isFinishing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("議事録を保存中…").font(.caption)
                }
            } else {
                Button {
                    Task { await meetingRecorder.start() }
                } label: {
                    Label("会議録音を開始", systemImage: "record.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if let err = meetingRecorder.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Button("議事録フォルダを開く") {
                try? FileManager.default.createDirectory(
                    at: MeetingRecorder.meetingsDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(MeetingRecorder.meetingsDir)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

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
