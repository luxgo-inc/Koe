import Foundation
import Testing
@testable import KoeCore

@Suite struct ReplacementDictionaryTests {
    @Test func ルールが配列順に適用される() {
        let dict = ReplacementDictionary(rules: [
            .init(from: "いーすぺーす", to: "E-Space"),
            .init(from: "E-Space基地", to: "E-Space HQ"),
        ])
        #expect(dict.apply(to: "いーすぺーす基地へ") == "E-Space HQへ")
    }

    @Test func 空辞書は素通し() {
        #expect(ReplacementDictionary(rules: []).apply(to: "そのまま") == "そのまま")
    }

    @Test func 保存して読み戻せる() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-repl-\(UUID().uuidString).json")
        let dict = ReplacementDictionary(rules: [.init(from: "a", to: "b")])
        try dict.save(to: url)
        let loaded = ReplacementDictionary.load(from: url)
        #expect(loaded.rules == dict.rules)
    }

    @Test func ファイル無し破損時は空辞書() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-repl-missing-\(UUID().uuidString).json")
        #expect(ReplacementDictionary.load(from: missing).rules.isEmpty)
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-repl-broken-\(UUID().uuidString).json")
        try Data("oops".utf8).write(to: broken)
        #expect(ReplacementDictionary.load(from: broken).rules.isEmpty)
    }
}
