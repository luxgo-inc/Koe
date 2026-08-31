import SwiftUI
import UserNotifications

@main
struct KoeApp: App {
    @State private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra("Koe", systemImage: controller.isRecording ? "mic.fill" : "mic") {
            MenuContent(controller: controller)
                .task {
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert])
                    await controller.startup()
                }
        }
        Settings {
            SettingsView(controller: controller)
        }
    }
}

struct MenuContent: View {
    @Bindable var controller: RecordingController

    var body: some View {
        Toggle("AI整形を有効にする", isOn: Binding(
            get: { controller.settings.aiRefinementEnabled },
            set: { controller.settings.aiRefinementEnabled = $0 }
        ))
        Divider()
        SettingsLink { Text("設定…") }
        Button("権限の状態を確認…") { PermissionsWindow.show() }
        Divider()
        Button("Koe を終了") { NSApplication.shared.terminate(nil) }
    }
}
