import AVFoundation
import Foundation
import KoeCore

/// 参考音声モード用のライター。マイクのバッファを入力のサンプルレートのまま（リサンプリングなし）
/// モノラル 24bit 整数 PCM に変換して一時ファイルへ追記し、停止時に無音をトリムして WAV に仕上げる。
///
/// append() はリアルタイムオーディオスレッドから呼ばれるため、変換と I/O は専用シリアルキューで行う
/// （DiarizationAudioWriter と同じ構造）。無音判定のために 10ms ブロックごとのピークだけを
/// メモリに持ち、音声本体は常にファイル側にあるので、数分の録音でもメモリに全部は載せない。
public final class ReferenceAudioWriter: @unchecked Sendable {
    public static let bitsPerSample = 24
    public static let bytesPerFrame = 3
    /// 無音判定のブロック長（秒）
    public static let blockSeconds: Double = 0.01

    public enum WriterError: LocalizedError {
        case unsupportedFormat
        case nothingRecorded
        /// 録音中の一時ファイルへの書き込みが失敗した（ディスク満杯など）。
        case writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "この入力フォーマットは保存できません（Float32 PCM のみ）"
            case .nothingRecorded: "音声が1フレームも届きませんでした"
            case .writeFailed(let reason): "一時ファイルへの書き込みに失敗しました: \(reason)"
            }
        }
    }

    /// 仕上がった WAV の情報。
    public struct Result: Sendable {
        public let url: URL
        public let sampleRate: Double
        /// トリム後の長さ（秒）
        public let durationSec: Double
        /// トリム前の長さ（秒）
        public let rawDurationSec: Double
    }

    private let queue = DispatchQueue(label: "jp.luxgo.koe.reference-writer", qos: .userInitiated)
    private let rawURL: URL
    private var handle: FileHandle?
    // 以下は queue 上でのみ触る
    private var sampleRate: Double = 0
    private var framesPerBlock = 0
    private var totalFrames = 0
    private var blockPeaks: [Float] = []
    private var currentBlockPeak: Float = 0
    private var currentBlockFrames = 0
    private var scratch: [UInt8] = []
    /// 録音中に起きた書き込みエラー。以降の append は捨て、finish() でこれを投げる。
    private var writeError: Error?

    public init() {
        rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-\(UUID().uuidString).pcm24")
    }

    /// 録音開始前（AudioRecorder.start() の前）に呼ぶ。サンプルレートは最初に届いたバッファから
    /// 決める（キープアライブ中は start() の直後からバッファが届くため、事前にフォーマットを
    /// 渡す設計だと取りこぼしや取り違えが起きる）。
    public func start() throws {
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        let h = try FileHandle(forWritingTo: rawURL)
        queue.sync {
            handle = h
            sampleRate = 0
            framesPerBlock = 0
            totalFrames = 0
            blockPeaks = []
            currentBlockPeak = 0
            currentBlockFrames = 0
            writeError = nil
        }
    }

    /// オーディオスレッドから呼ぶ。タップのバッファはコールバック内でしか有効でないため、
    /// キューへ渡す前にモノラル Float32 へコピーする（1024 フレームなら 4KB）。
    /// Float32 以外のフォーマットは無視する（AudioRecorder のタップは常に Float32）。
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if channelCount == 1 || buffer.format.isInterleaved {
            // インターリーブの場合は ch0 だけ拾う（マイク入力は通常 non-interleaved）
            let stride = buffer.format.isInterleaved ? channelCount : 1
            let src = channels[0]
            for i in 0..<n { mono[i] = src[i * stride] }
        } else {
            let scale = 1 / Float(channelCount)
            for c in 0..<channelCount {
                let src = channels[c]
                for i in 0..<n { mono[i] += src[i] * scale }
            }
        }
        queue.async { [self] in write(mono, sampleRate: rate) }
    }

    /// queue 上でのみ呼ぶ。Float32 → Int24 LE に変換して追記し、ブロックピークを更新する。
    /// 録音途中でサンプルレートが変わったバッファ（デバイス切替）はリサンプリングせず捨てる。
    private func write(_ samples: [Float], sampleRate rate: Double) {
        guard let handle, rate > 0, writeError == nil else { return }
        if sampleRate == 0 {
            sampleRate = rate
            framesPerBlock = max(1, Int((rate * Self.blockSeconds).rounded()))
        } else if abs(sampleRate - rate) > 0.5 {
            return
        }
        let n = samples.count
        if scratch.count < n * Self.bytesPerFrame {
            scratch = [UInt8](repeating: 0, count: n * Self.bytesPerFrame)
        }
        for i in 0..<n {
            let s = samples[i]
            let clamped = max(-1, min(1, s))
            // 24bit フルスケール。+1.0 は 8388607 に丸める
            let v = Int32((clamped * 8_388_607).rounded())
            let u = UInt32(bitPattern: v)
            scratch[i * 3] = UInt8(u & 0xff)
            scratch[i * 3 + 1] = UInt8((u >> 8) & 0xff)
            scratch[i * 3 + 2] = UInt8((u >> 16) & 0xff)

            let a = abs(s)
            if a > currentBlockPeak { currentBlockPeak = a }
            currentBlockFrames += 1
            if currentBlockFrames == framesPerBlock {
                blockPeaks.append(currentBlockPeak)
                currentBlockPeak = 0
                currentBlockFrames = 0
            }
        }
        // 旧 API の write(_:) はディスク満杯などで ObjC 例外を投げてプロセスごと落とすため、
        // Swift エラーを返す write(contentsOf:) を使い、失敗は保持して finish() で報告する。
        do {
            try handle.write(contentsOf: Data(scratch[0..<(n * Self.bytesPerFrame)]))
            totalFrames += n
        } catch {
            writeError = error
            try? handle.close()
            self.handle = nil
        }
    }

    /// 書き込みを締め、（必要なら）前後の無音を切って WAV を destination に書き出す。
    /// 一時ファイルから 1MB ずつコピーするので、録音全体をメモリに載せない。
    /// 戻ったら一時ファイルは消えている。
    public func finish(to destination: URL, trim: SilenceTrimmer?) throws -> Result {
        var captured: (sampleRate: Double, totalFrames: Int, peaks: [Float], framesPerBlock: Int) = (0, 0, [], 0)
        var failure: Error?
        queue.sync { [self] in
            if currentBlockFrames > 0 { blockPeaks.append(currentBlockPeak) }
            try? handle?.close()
            handle = nil
            captured = (sampleRate, totalFrames, blockPeaks, framesPerBlock)
            failure = writeError
        }
        defer { try? FileManager.default.removeItem(at: rawURL) }
        if let failure { throw WriterError.writeFailed(failure.localizedDescription) }
        guard captured.totalFrames > 0 else { throw WriterError.nothingRecorded }

        let range: Range<Int>
        if let trim {
            range = trim.trimRange(
                blockPeaks: captured.peaks, framesPerBlock: captured.framesPerBlock,
                totalFrames: captured.totalFrames, sampleRate: captured.sampleRate)
        } else {
            range = 0..<captured.totalFrames
        }
        let dataBytes = range.count * Self.bytesPerFrame
        let header = WAVHeader.make(
            sampleRate: Int(captured.sampleRate.rounded()), channels: 1,
            bitsPerSample: Self.bitsPerSample, dataByteCount: dataBytes)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        let input = try FileHandle(forReadingFrom: rawURL)
        defer {
            try? out.close()
            try? input.close()
        }
        try out.write(contentsOf: header)
        try input.seek(toOffset: UInt64(range.lowerBound * Self.bytesPerFrame))
        var remaining = dataBytes
        let chunk = 1 << 20
        while remaining > 0 {
            let data = try input.read(upToCount: min(chunk, remaining)) ?? Data()
            if data.isEmpty { break }
            try out.write(contentsOf: data)
            remaining -= data.count
        }
        return Result(
            url: destination,
            sampleRate: captured.sampleRate,
            durationSec: Double(range.count) / captured.sampleRate,
            rawDurationSec: Double(captured.totalFrames) / captured.sampleRate)
    }

    /// 何も残さず破棄する（Esc キャンセル・開始失敗時）。
    public func discard() {
        queue.sync { [self] in
            try? handle?.close()
            handle = nil
            totalFrames = 0
            blockPeaks = []
        }
        try? FileManager.default.removeItem(at: rawURL)
    }
}
