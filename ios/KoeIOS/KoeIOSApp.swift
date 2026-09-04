import SwiftUI

@main
struct KoeIOSApp: App {
    @State private var session = MeetingSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("録音", systemImage: "mic.circle.fill") {
                    RecordView(session: session)
                }
                Tab("履歴", systemImage: "doc.text") {
                    HistoryView()
                }
                Tab("設定", systemImage: "gearshape") {
                    IOSSettingsView()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await UploadQueue.shared.drain() }
            }
        }
    }
}
