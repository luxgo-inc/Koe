import Foundation

/// 録音の前後の無音を切る範囲を決める純関数。
/// 音声そのものではなく、固定長ブロック（既定 10ms）ごとのピーク振幅（0〜1）の配列を受け取る。
/// 録音中にブロックピークだけを貯めておけば、数分の録音でも音声全体をメモリに載せずに済む。
public struct SilenceTrimmer: Sendable {
    /// これ以上のピークがあるブロックを「音あり」とみなす（dBFS）。
    public var thresholdDB: Double
    /// 音の前後に残す無音の長さ（秒）。切りすぎを避けるためのマージン。
    public var padding: Double

    public static let defaultThresholdDB: Double = -40
    public static let defaultPadding: Double = 0.3

    public init(thresholdDB: Double = defaultThresholdDB, padding: Double = defaultPadding) {
        self.thresholdDB = thresholdDB
        self.padding = padding
    }

    /// 線形振幅での閾値。
    public var thresholdAmplitude: Float {
        Float(pow(10, thresholdDB / 20))
    }

    /// 残すフレーム範囲を返す。
    /// - blockPeaks: ブロックごとのピーク振幅（先頭から順）
    /// - framesPerBlock: 1ブロックのフレーム数
    /// - totalFrames: 録音全体のフレーム数（最後のブロックは端数のことがある）
    /// - sampleRate: パディング秒→フレーム換算に使う
    /// 全ブロックが無音のときは何も切らず全体を返す（誤って空ファイルにしない）。
    public func trimRange(
        blockPeaks: [Float], framesPerBlock: Int, totalFrames: Int, sampleRate: Double
    ) -> Range<Int> {
        let full = 0..<max(totalFrames, 0)
        guard totalFrames > 0, framesPerBlock > 0, !blockPeaks.isEmpty else { return full }
        let threshold = thresholdAmplitude
        guard let firstLoud = blockPeaks.firstIndex(where: { $0 >= threshold }),
              let lastLoud = blockPeaks.lastIndex(where: { $0 >= threshold })
        else { return full }

        let pad = Int((padding * sampleRate).rounded())
        let start = max(0, firstLoud * framesPerBlock - pad)
        // 音ありの最終ブロックの末尾＋パディング
        let end = min(totalFrames, (lastLoud + 1) * framesPerBlock + pad)
        guard start < end else { return full }
        return start..<end
    }
}
