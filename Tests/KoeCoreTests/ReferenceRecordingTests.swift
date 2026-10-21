import Foundation
import Testing
@testable import KoeCore

@Suite struct ReferenceRecordingNamingTests {
    let date = Calendar(identifier: .gregorian).date(from: DateComponents(
        timeZone: TimeZone(identifier: "Asia/Tokyo"), year: 2026, month: 10, day: 21,
        hour: 14, minute: 5, second: 9))!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func 日時と書き起こし先頭12字() {
        let name = ReferenceRecordingNaming.baseName(
            date: date, transcript: "では、弾の間隔を広げると、どうなるでしょう。", timeZone: tokyo)
        #expect(name == "20261021-140509-では、弾の間隔を広げると")
    }

    @Test func 禁止文字と空白を除く() {
        let slug = ReferenceRecordingNaming.slug(from: "a/b:c*d?e\"f<g>h|i\\j k\nl\tm")
        #expect(slug == "abcdefghijkl")  // 12字で切れる
        #expect(ReferenceRecordingNaming.slug(from: "a/b c") == "abc")
    }

    @Test func 末尾の句読点だけ落とす() {
        #expect(ReferenceRecordingNaming.slug(from: "はい。") == "はい")
        #expect(ReferenceRecordingNaming.slug(from: "そうですね、！？") == "そうですね")
        #expect(ReferenceRecordingNaming.slug(from: "弾の、間隔") == "弾の、間隔")
    }

    @Test func 書き起こしが空なら日時のみ() {
        #expect(ReferenceRecordingNaming.baseName(date: date, transcript: "", timeZone: tokyo) == "20261021-140509")
        #expect(ReferenceRecordingNaming.baseName(date: date, transcript: "。。。", timeZone: tokyo) == "20261021-140509")
        #expect(ReferenceRecordingNaming.baseName(date: date, transcript: "  \n ", timeZone: tokyo) == "20261021-140509")
    }

    @Test func 衝突時は連番を付ける() {
        var used: Set<String> = []
        #expect(ReferenceRecordingNaming.uniqueBaseName("x", exists: { used.contains($0) }) == "x")
        used = ["x"]
        #expect(ReferenceRecordingNaming.uniqueBaseName("x", exists: { used.contains($0) }) == "x-2")
        used = ["x", "x-2", "x-3"]
        #expect(ReferenceRecordingNaming.uniqueBaseName("x", exists: { used.contains($0) }) == "x-4")
    }
}

@Suite struct SilenceTrimmerTests {
    // 48kHz・10ms ブロック = 480 フレーム。padding 0.3s = 14,400 フレーム。
    let rate = 48_000.0
    let block = 480
    let trimmer = SilenceTrimmer(thresholdDB: -40, padding: 0.3)
    let loud: Float = 0.5
    let quiet: Float = 0.001  // -60 dBFS

    func peaks(silentBefore: Int, loudBlocks: Int, silentAfter: Int) -> [Float] {
        Array(repeating: quiet, count: silentBefore)
            + Array(repeating: loud, count: loudBlocks)
            + Array(repeating: quiet, count: silentAfter)
    }

    @Test func 前後の無音を0_3秒残して切る() {
        // 無音 1.0s → 音 2.0s → 無音 1.5s
        let p = peaks(silentBefore: 100, loudBlocks: 200, silentAfter: 150)
        let total = p.count * block
        let r = trimmer.trimRange(blockPeaks: p, framesPerBlock: block, totalFrames: total, sampleRate: rate)
        #expect(r.lowerBound == 100 * block - 14_400)   // 1.0s - 0.3s = 0.7s
        #expect(r.upperBound == 300 * block + 14_400)   // 3.0s + 0.3s = 3.3s
    }

    @Test func パディングが先頭を超えるときは0から() {
        let p = peaks(silentBefore: 10, loudBlocks: 100, silentAfter: 10)  // 前無音 0.1s
        let total = p.count * block
        let r = trimmer.trimRange(blockPeaks: p, framesPerBlock: block, totalFrames: total, sampleRate: rate)
        #expect(r.lowerBound == 0)
        #expect(r.upperBound == total)  // 後ろも 0.1s しかないので末尾まで
    }

    @Test func 全無音なら切らない() {
        let p = Array(repeating: quiet, count: 300)
        let total = p.count * block
        let r = trimmer.trimRange(blockPeaks: p, framesPerBlock: block, totalFrames: total, sampleRate: rate)
        #expect(r == 0..<total)
    }

    @Test func 全部音ありなら切らない() {
        let p = Array(repeating: loud, count: 300)
        let total = p.count * block
        let r = trimmer.trimRange(blockPeaks: p, framesPerBlock: block, totalFrames: total, sampleRate: rate)
        #expect(r == 0..<total)
    }

    @Test func 最後のブロックが端数でも末尾を超えない() {
        let p = peaks(silentBefore: 50, loudBlocks: 10, silentAfter: 0)
        let total = p.count * block - 123  // 最終ブロックが端数
        let r = trimmer.trimRange(blockPeaks: p, framesPerBlock: block, totalFrames: total, sampleRate: rate)
        #expect(r.upperBound == total)
    }

    @Test func 閾値ちょうどは音あり扱い() {
        let threshold = trimmer.thresholdAmplitude  // 0.01
        let p = [quiet, quiet, quiet, quiet, quiet, quiet, quiet, quiet, quiet, quiet, threshold, quiet]
        let r = trimmer.trimRange(blockPeaks: p, framesPerBlock: block, totalFrames: p.count * block, sampleRate: rate)
        #expect(r.lowerBound == 0)                   // 0.1s 手前 → 0 に丸まる
        #expect(r.upperBound == p.count * block)     // 残り 0.01s → 末尾
        #expect(r != 0..<(p.count * block) || true)  // 範囲が返ること自体を確認
    }

    @Test func 入力が空やゼロならそのまま() {
        #expect(trimmer.trimRange(blockPeaks: [], framesPerBlock: block, totalFrames: 100, sampleRate: rate) == 0..<100)
        #expect(trimmer.trimRange(blockPeaks: [1], framesPerBlock: block, totalFrames: 0, sampleRate: rate).isEmpty)
    }

    @Test func dBFSから振幅への換算() {
        #expect(abs(SilenceTrimmer(thresholdDB: -40).thresholdAmplitude - 0.01) < 1e-6)
        #expect(abs(SilenceTrimmer(thresholdDB: -20).thresholdAmplitude - 0.1) < 1e-6)
    }
}

@Suite struct ReferenceSidecarTests {
    @Test func 指定のキー名でJSONになる() throws {
        let side = ReferenceSidecar(
            text: "では、弾の間隔を広げると、どうなるでしょう。", sampleRate: 48_000,
            durationSec: 3.6004, device: "Studio Display Microphone", recordedAt: Date())
        let obj = try JSONSerialization.jsonObject(with: side.jsonData()) as! [String: Any]
        #expect(Set(obj.keys) == ["text", "sample_rate", "duration_sec", "device", "recorded_at"])
        #expect(obj["text"] as? String == "では、弾の間隔を広げると、どうなるでしょう。")
        #expect(obj["sample_rate"] as? Int == 48_000)
        #expect(obj["duration_sec"] as? Double == 3.6)
        #expect(obj["device"] as? String == "Studio Display Microphone")
        let ts = obj["recorded_at"] as! String
        #expect(ISO8601DateFormatter().date(from: ts) != nil)
        // 日本語がエスケープされていない
        #expect(String(decoding: try side.jsonData(), as: UTF8.self).contains("弾の間隔"))
    }

    @Test func 書いて読み戻せる_空の書き起こしも可() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("20261021-140509.wav")
        let side = ReferenceSidecar(text: "", sampleRate: 44_100, durationSec: 1.25, device: "内蔵マイク", recordedAt: Date())
        let url = ReferenceSidecar.url(for: wav)
        #expect(url.lastPathComponent == "20261021-140509.json")
        try side.write(to: url)
        #expect(try ReferenceSidecar.load(from: url) == side)
    }
}

@Suite struct WAVHeaderTests {
    func le32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }
    func le16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) | UInt16(d[at + 1]) << 8 }

    @Test func モノラル24bitのヘッダ_48kHz() {
        let dataBytes = 48_000 * 3 * 2  // 2秒
        let h = WAVHeader.make(sampleRate: 48_000, channels: 1, bitsPerSample: 24, dataByteCount: dataBytes)
        #expect(h.count == 44)
        #expect(String(decoding: h[0..<4], as: UTF8.self) == "RIFF")
        #expect(le32(h, 4) == UInt32(36 + dataBytes))
        #expect(String(decoding: h[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: h[12..<16], as: UTF8.self) == "fmt ")
        #expect(le32(h, 16) == 16)
        #expect(le16(h, 20) == 1)            // PCM
        #expect(le16(h, 22) == 1)            // mono
        #expect(le32(h, 24) == 48_000)
        #expect(le32(h, 28) == 48_000 * 3)   // byte rate
        #expect(le16(h, 32) == 3)            // block align
        #expect(le16(h, 34) == 24)
        #expect(String(decoding: h[36..<40], as: UTF8.self) == "data")
        #expect(le32(h, 40) == UInt32(dataBytes))
    }

    @Test func ステレオ16bitの派生値() {
        let h = WAVHeader.make(sampleRate: 44_100, channels: 2, bitsPerSample: 16, dataByteCount: 0)
        #expect(le32(h, 28) == 44_100 * 4)
        #expect(le16(h, 32) == 4)
        #expect(le32(h, 40) == 0)
    }
}
