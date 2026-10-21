import AVFoundation
import Foundation
import KoeCore
import KoeKit
import Testing

/// 合成音声（無音→正弦波→無音）を 1024 フレームずつ流し、WAV が入力レートのまま
/// モノラル 24bit で書かれ、前後の無音が 0.3 秒だけ残ることを確認する。
struct ReferenceAudioWriterTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("koe-ref-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// silenceBefore / tone / silenceAfter 秒の合成音をライターに流し込む。
    func feed(_ writer: ReferenceAudioWriter, rate: Double, channels: AVAudioChannelCount,
              silenceBefore: Double, tone: Double, silenceAfter: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let total = Int((silenceBefore + tone + silenceAfter) * rate)
        let toneStart = Int(silenceBefore * rate)
        let toneEnd = toneStart + Int(tone * rate)
        var offset = 0
        while offset < total {
            let n = min(1024, total - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<Int(channels) {
                let data = buffer.floatChannelData![c]
                for i in 0..<n {
                    let idx = offset + i
                    let inTone = idx >= toneStart && idx < toneEnd
                    data[i] = inTone ? 0.5 * sin(2 * .pi * 440 * Double(idx) / rate).f : 0.0005
                }
            }
            writer.append(buffer)
            offset += n
        }
    }

    func le32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }
    func le16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) | UInt16(d[at + 1]) << 8 }

    @Test func 入力レートのまま24bitモノラルで前後0_3秒を残して保存される() throws {
        let writer = ReferenceAudioWriter()
        try writer.start()
        feed(writer, rate: 48_000, channels: 1, silenceBefore: 1.0, tone: 2.0, silenceAfter: 1.5)
        let out = tempDir().appendingPathComponent("a.wav")
        let result = try writer.finish(to: out, trim: SilenceTrimmer())

        #expect(result.sampleRate == 48_000)
        #expect(abs(result.rawDurationSec - 4.5) < 0.001)
        #expect(abs(result.durationSec - 2.6) < 0.02)  // 0.3 + 2.0 + 0.3

        let data = try Data(contentsOf: out)
        #expect(le16(data, 22) == 1)          // mono
        #expect(le32(data, 24) == 48_000)
        #expect(le16(data, 34) == 24)
        #expect(Int(le32(data, 40)) == data.count - 44)
        #expect(data.count - 44 == Int(result.durationSec * 48_000) * 3)

        // 先頭 0.3 秒は無音、その直後から音がある
        func sample(_ frame: Int) -> Int32 {
            let o = 44 + frame * 3
            let u = UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16
            return Int32(bitPattern: u << 8) >> 8
        }
        var headPeak: Int32 = 0
        for f in 0..<(14_400 - 480) { headPeak = max(headPeak, abs(sample(f))) }
        #expect(headPeak < 20_000)  // -52 dBFS 以下
        var tonePeak: Int32 = 0
        for f in 14_400..<(14_400 + 4800) { tonePeak = max(tonePeak, abs(sample(f))) }
        #expect(tonePeak > 4_000_000)  // 0.5 フルスケール ≈ 4,194,303
    }

    @Test func トリムOFFなら全体が残り_ステレオはモノラルに落ちる() throws {
        let writer = ReferenceAudioWriter()
        try writer.start()
        feed(writer, rate: 44_100, channels: 2, silenceBefore: 0.5, tone: 0.5, silenceAfter: 0.5)
        let out = tempDir().appendingPathComponent("b.wav")
        let result = try writer.finish(to: out, trim: nil)
        #expect(result.sampleRate == 44_100)
        #expect(abs(result.durationSec - 1.5) < 0.001)
        let data = try Data(contentsOf: out)
        #expect(le16(data, 22) == 1)
        #expect(le32(data, 24) == 44_100)
        #expect(data.count == 44 + Int(1.5 * 44_100) * 3)
    }

    @Test func 全無音でも空ファイルにならない() throws {
        let writer = ReferenceAudioWriter()
        try writer.start()
        feed(writer, rate: 48_000, channels: 1, silenceBefore: 1.0, tone: 0, silenceAfter: 0)
        let out = tempDir().appendingPathComponent("c.wav")
        let result = try writer.finish(to: out, trim: SilenceTrimmer())
        #expect(abs(result.durationSec - 1.0) < 0.001)
    }

    @Test func フレームが無ければエラー_discard後も同様() throws {
        let writer = ReferenceAudioWriter()
        try writer.start()
        let out = tempDir().appendingPathComponent("d.wav")
        #expect(throws: ReferenceAudioWriter.WriterError.self) {
            try writer.finish(to: out, trim: nil)
        }
        let leftover = (try? Data(contentsOf: out))?.count ?? 0
        #expect(leftover <= 44)

        let w2 = ReferenceAudioWriter()
        try w2.start()
        feed(w2, rate: 48_000, channels: 1, silenceBefore: 0, tone: 0.1, silenceAfter: 0)
        w2.discard()
        #expect(throws: ReferenceAudioWriter.WriterError.self) {
            try w2.finish(to: out, trim: nil)
        }
    }

    @Test func 途中でサンプルレートが変わったバッファは捨てる() throws {
        let writer = ReferenceAudioWriter()
        try writer.start()
        feed(writer, rate: 48_000, channels: 1, silenceBefore: 0, tone: 1.0, silenceAfter: 0)
        feed(writer, rate: 44_100, channels: 1, silenceBefore: 0, tone: 1.0, silenceAfter: 0)
        let out = tempDir().appendingPathComponent("e.wav")
        let result = try writer.finish(to: out, trim: nil)
        #expect(result.sampleRate == 48_000)
        #expect(abs(result.durationSec - 1.0) < 0.001)
    }
}

private extension Double {
    var f: Float { Float(self) }
}
