import AppKit
import KoeCore
import SwiftUI

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Koe 履歴"
            w.contentView = NSHostingView(rootView: HistoryView())
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var query = ""
    @State private var copiedTS: String?

    private let logger = HistoryLogger(directory: RecordingController.appSupportDir)

    private var filtered: [HistoryEntry] {
        let reversed = entries.reversed()  // 新しい順
        guard !query.isEmpty else { return Array(reversed) }
        return reversed.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("全削除") {
                    let alert = NSAlert()
                    alert.messageText = "履歴を全削除しますか？"
                    alert.addButton(withTitle: "削除")
                    alert.addButton(withTitle: "キャンセル")
                    if alert.runModal() == .alertFirstButtonReturn {
                        try? logger.clear()
                        reload()
                    }
                }
            }
            .padding(10)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "履歴はまだありません" : "一致する履歴がありません",
                    systemImage: "clock")
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered, id: \.ts) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(formatTS(entry.ts))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.mode == "refined" ? "AI整形" : "素のまま")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(entry.mode == "refined" ? Color.purple.opacity(0.2) : Color.gray.opacity(0.2),
                                            in: Capsule())
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                                copiedTS = entry.ts
                            } label: {
                                Image(systemName: copiedTS == entry.ts ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            Button {
                                try? logger.remove(entry)
                                reload()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        Text(entry.text).lineLimit(3).textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        entries = logger.entries()
    }

    private func formatTS(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
