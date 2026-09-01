import Foundation

public struct PromptPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var instruction: String
    public init(id: UUID = UUID(), name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }
}

/// AI整形プロンプトのプリセット集。ファイル永続化＋選択IDは呼び出し側がUserDefaultsで保持。
public struct PromptPresetStore: Sendable {
    public private(set) var presets: [PromptPreset]
    public var selectedID: UUID

    public var selected: PromptPreset {
        presets.first { $0.id == selectedID } ?? presets[0]
    }

    /// ファイルが無い初回はデフォルト1件を生成。旧 refinementInstruction のカスタム値が
    /// あれば「カスタム」プリセットとして取り込み選択する（マイグレーション）。
    public static func load(
        from url: URL,
        legacyCustomInstruction: String?,
        storedSelectedID: String?
    ) -> PromptPresetStore {
        if let data = try? Data(contentsOf: url),
           let presets = try? JSONDecoder().decode([PromptPreset].self, from: data),
           !presets.isEmpty {
            let selected = storedSelectedID.flatMap(UUID.init(uuidString:)) ?? presets[0].id
            let valid = presets.contains { $0.id == selected } ? selected : presets[0].id
            return PromptPresetStore(presets: presets, selectedID: valid)
        }
        var presets = [PromptPreset(name: "AIエージェント用",
                                    instruction: RefinementPromptBuilder.defaultInstruction)]
        var selectedID = presets[0].id
        if let legacy = legacyCustomInstruction,
           legacy != RefinementPromptBuilder.defaultInstruction {
            let custom = PromptPreset(name: "カスタム", instruction: legacy)
            presets.append(custom)
            selectedID = custom.id
        }
        return PromptPresetStore(presets: presets, selectedID: selectedID)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(presets).write(to: url)
    }

    @discardableResult
    public mutating func add(name: String, instruction: String) -> PromptPreset {
        let preset = PromptPreset(name: name, instruction: instruction)
        presets.append(preset)
        return preset
    }

    public mutating func update(_ preset: PromptPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i] = preset
    }

    /// 最後の1件は削除しない。選択中を消したら先頭へフォールバック。
    public mutating func remove(id: UUID) {
        guard presets.count > 1 else { return }
        presets.removeAll { $0.id == id }
        if !presets.contains(where: { $0.id == selectedID }) {
            selectedID = presets[0].id
        }
    }
}
