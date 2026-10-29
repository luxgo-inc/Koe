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
        // 最初に仕込む（以降の初期化中のクラッシュも記録するため）
        CrashReporter.install()
        let c = RecordingController()
        let m = MeetingRecorder()
        _controller = State(initialValue: c)
        _meetingRecorder = State(initialValue: m)
        // 開発用スモークフックは debug ビルドにだけ含める。リリースビルド（build-app.sh の
        // -c release）に残すと、同一ユーザーの任意プロセスが起動引数だけで Koe の
        // マイク／システム音声の TCC 許可を借りて録音・書き起こしできてしまうため。
        #if DEBUG
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
        // 開発用スモークフック: `KoeApp --crash-smoke` で CrashReporter の記録を検証する。
        // 3秒後に AppKit が握りつぶす NSException を投げ、さらに2秒後に SIGSEGV で落ちる。
        // ~/Library/Logs/Koe/crashes/ に exception-*.log と signal-*.log が出れば正常。
        if ProcessInfo.processInfo.arguments.contains("--crash-smoke") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                NSException(name: .genericException, reason: "crash-smoke", userInfo: nil).raise()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                raise(SIGSEGV)
            }
        }
        #endif
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
    @Environment(\.openSettings) private var openSettings
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

            // 直前の参考音声（F11）
            if let reference = controller.lastReferenceRecording {
                Divider()
                ReferenceRecordingRow(info: reference, controller: controller)
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
                Button("設定…") { showSettings() }
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
            controller.reloadLastReferenceRecording()
            permissionsMissing = !(CGPreflightListenEventAccess() && CGPreflightPostEventAccess())
        }
    }

    /// 「直前の参考音声」1件。再生 / Finder で表示 / 削除。
struct ReferenceRecordingRow: View {
    let info: ReferenceRecordingInfo
    let controller: RecordingController
    @State private var player: NSSound?
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("直前の参考音声").font(.caption).foregroundStyle(.secondary)
            Text(info.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Text(String(format: "%.1f秒", info.durationSec))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                }
                .help(isPlaying ? "停止" : "再生")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([info.url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Finder で表示")
                Button {
                    stopPlayback()
                    controller.deleteLastReferenceRecording()
                } label: {
                    Image(systemName: "trash")
                }
                .help("WAV と JSON を削除")
            }
            .buttonStyle(.borderless)
        }
        .onDisappear { stopPlayback() }
        .onChange(of: info) { _, _ in stopPlayback() }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard let sound = NSSound(contentsOf: info.url, byReference: true) else { return }
        player = sound
        isPlaying = sound.play()
        // 再生終了で表示を戻す（デリゲートを持つより単純）
        let duration = sound.duration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            if player === sound, !sound.isPlaying { stopPlayback() }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

/// LSUIElement のアクセサリアプリは窓を開いてもアプリがアクティブにならないため、
    /// SettingsLink をそのまま使うと設定ウインドウが他アプリの背面に出たままになる。
    /// activate してから openSettings し、ウインドウ生成を待って明示的に前面化する。
    private func showSettings() {
        NSApp.activate()
        openSettings()
        Task { @MainActor in await SettingsWindow.bringToFront() }
    }
}

/// SwiftUI の Settings シーンが作るウインドウを前面へ出すヘルパ。
/// 2回目以降の「設定…」は onAppear が走らず背面に残るだけなので、毎回ここを通す。
@MainActor
enum SettingsWindow {
    private static let identifier = "com_apple_SwiftUI_Settings_window"

    /// openSettings() 直後はウインドウがまだ存在しないことがあるため最大 500ms 待つ。
    static func bringToFront(retries: Int = 10) async {
        for _ in 0..<retries {
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == identifier
            }) {
                NSApp.activate()
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        NSApp.activate()
    }
}
