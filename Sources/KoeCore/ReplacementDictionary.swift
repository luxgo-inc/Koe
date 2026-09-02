import Foundation

public struct ReplacementRule: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 固定文字列の置換辞書。配列順に適用。認識確定直後（AI整形の前）に使う。
public struct ReplacementDictionary: Sendable {
    public var rules: [ReplacementRule]

    public init(rules: [ReplacementRule]) {
        self.rules = rules
    }

    public func apply(to text: String) -> String {
        rules.reduce(text) { $0.replacingOccurrences(of: $1.from, with: $1.to) }
    }

    public static func load(from url: URL) -> ReplacementDictionary {
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([ReplacementRule].self, from: data)
        else { return ReplacementDictionary(rules: []) }
        return ReplacementDictionary(rules: rules)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(rules).write(to: url)
    }
}
