import AppKit
import AVFoundation
import SwiftUI

/// 権限状態の一覧と設定画面への誘導。
@MainActor
enum PermissionsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Koe の権限"
            w.contentView = NSHostingView(rootView: PermissionsView())
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct PermissionsView: View {
    @State private var micGranted = false
    @State private var listenGranted = false
    @State private var postGranted = false
    @State private var axGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("マイク", granted: micGranted,
                pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            row("入力監視（ホットキー捕捉）", granted: listenGranted,
                pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            row("アクセシビリティ（Cmd+V送信）", granted: postGranted || axGranted,
                pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            Text("権限を変更したら Koe を再起動してください（Event Tap の再生成のため）。")
                .font(.caption).foregroundStyle(.secondary)
            Button("再チェック") { refresh() }
        }
        .padding(20)
        .onAppear { refresh() }
    }

    private func row(_ label: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
            Text(label)
            Spacer()
            if !granted {
                Button("設定を開く") {
                    NSWorkspace.shared.open(URL(string: pane)!)
                }
            }
        }
    }

    private func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        listenGranted = CGPreflightListenEventAccess()
        postGranted = CGPreflightPostEventAccess()
        axGranted = AXIsProcessTrusted()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in micGranted = ok }
            }
        }
        if !listenGranted { _ = CGRequestListenEventAccess() }
        if !postGranted { _ = CGRequestPostEventAccess() }
    }
}
