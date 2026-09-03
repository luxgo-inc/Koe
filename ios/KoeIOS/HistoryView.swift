import SwiftUI

/// Documents/meetings の議事録一覧。プレビュー・共有・削除・手動アップロード。
struct HistoryView: View {
    @State private var files: [URL] = []
    @State private var queue = UploadQueue.shared

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    ContentUnavailableView(
                        "議事録はまだありません",
                        systemImage: "doc.text",
                        description: Text("録音タブから会議やメモを録音すると、ここに保存されます。"))
                } else {
                    List {
                        ForEach(files, id: \.self) { url in
                            NavigationLink(value: url) {
                                HStack {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .lineLimit(1)
                                    Spacer()
                                    statusBadge(for: url)
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("履歴")
            .navigationDestination(for: URL.self) { url in
                MeetingDetailView(url: url)
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
        }
    }

    @ViewBuilder
    private func statusBadge(for url: URL) -> some View {
        switch queue.status(for: url) {
        case .uploaded:
            Image(systemName: "checkmark.icloud").foregroundStyle(.green)
        case .pending:
            Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
        case .none:
            EmptyView()
        }
    }

    private func reload() {
        let dir = MeetingSession.meetingsDir
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        files = urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: files[index])
        }
        reload()
    }
}

struct MeetingDetailView: View {
    let url: URL
    @State private var content = ""
    @State private var queue = UploadQueue.shared
    @State private var uploadMessage: String?
    @State private var showRename = false

    var body: some View {
        ScrollView {
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRename = true
                } label: {
                    Image(systemName: "person.text.rectangle")
                }
                .disabled(SpeakerRenamer.speakers(in: content).isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        queue.enqueue(url)
                        await queue.drain()
                        uploadMessage = queue.status(for: url) == .uploaded
                            ? "Google Docs にアップロードしました"
                            : "アップロードできませんでした（設定でGoogleにサインインしているか確認）"
                    }
                } label: {
                    Image(systemName: "icloud.and.arrow.up")
                }
            }
        }
        .onAppear {
            content = (try? String(contentsOf: url, encoding: .utf8)) ?? "（読み込めませんでした）"
        }
        .sheet(isPresented: $showRename) {
            SpeakerRenameSheet(url: url, content: $content)
                .presentationDetents([.medium])
        }
        .alert("アップロード", isPresented: .init(
            get: { uploadMessage != nil },
            set: { if !$0 { uploadMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadMessage ?? "")
        }
    }
}
