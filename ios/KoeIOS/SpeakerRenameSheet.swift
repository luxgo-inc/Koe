import SwiftUI

/// 議事録 Markdown 中の話者ラベル（`**話者1**:` 等）を検出・一括リネームする。
enum SpeakerRenamer {
    /// `- [MM:SS] **話者**: テキスト` 形式から話者名を登場順に重複なしで抽出する。
    static func speakers(in markdown: String) -> [String] {
        var seen: [String] = []
        for line in markdown.split(separator: "\n") {
            guard let start = line.range(of: "] **"),
                  let end = line.range(of: "**:", range: start.upperBound..<line.endIndex) else { continue }
            let name = String(line[start.upperBound..<end.lowerBound])
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    static func rename(_ markdown: String, mapping: [String: String]) -> String {
        var result = markdown
        for (old, new) in mapping {
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != old else { continue }
            result = result.replacingOccurrences(of: "**\(old)**:", with: "**\(trimmed)**:")
        }
        return result
    }
}

struct SpeakerRenameSheet: View {
    let url: URL
    @Binding var content: String
    @Environment(\.dismiss) private var dismiss
    @State private var names: [(original: String, edited: String)] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($names, id: \.original) { $entry in
                        LabeledContent(entry.original) {
                            TextField("新しい名前", text: $entry.edited)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    Text("例: 話者1 → 田中さん。保存済みのこの議事録ファイルが書き換わります。Google Docs にアップロード済みの場合は、共有メニューから再アップロードしてください。")
                }
            }
            .navigationTitle("話者名を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                names = SpeakerRenamer.speakers(in: content).map { ($0, $0) }
            }
        }
    }

    private func save() {
        let mapping = Dictionary(
            uniqueKeysWithValues: names.map { ($0.original, $0.edited) })
        let updated = SpeakerRenamer.rename(content, mapping: mapping)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            content = updated
            dismiss()
        } catch {
            // 書き込み失敗時はシートを開いたままにする（再試行可能）
        }
    }
}
