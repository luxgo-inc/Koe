import Foundation

/// 録音の前後の無音を切る範囲を決める純関数。
/// 音声そのものではなく、固定長ブロック（既定 10ms）ごとの RMS（0〜1、線形）の配列を受け取る。
/// 録音中にブロック RMS だけを貯めておけば、数分の録音でも音声全体をメモリに載せずに済む。
///
/// ピークではなく RMS で見るのは、キーを押す音・録音開始時のポップ（実測: 先頭 60ms に
/// -0.3 dBFS のピーク、末尾に 10ms のクリック）や 3.5mm マイクのノイズ床（ピーク -25〜-40 dBFS）に
/// 引きずられないため。さらに「閾値以上が minimumSpeech 以上続く」区間だけを音声とみなす。
public struct SilenceTrimmer: Sendable {
    /// これ以上の RMS が続くブロックを「音声」とみなす（dBFS）。
    public var thresholdDB: Double
    /// 音声の前後に残す無音の長さ（秒）。切りすぎを避けるためのマージン。
    public var padding: Double
    /// 音声とみなすのに必要な連続時間（秒）。これより短い山（クリック・ポップ）は無視する。
    public var minimumSpeech: Double

    public static let defaultThresholdDB: Double = -38
    public static let defaultPadding: Double = 0.3
    public static let defaultMinimumSpeech: Double = 0.1

    public init(
        thresholdDB: Double = defaultThresholdDB,
        padding: Double = defaultPadding,
        minimumSpeech: Double = defaultMinimumSpeech
    ) {
        self.thresholdDB = thresholdDB
        self.padding = padding
        self.minimumSpeech = minimumSpeech
    }

    /// 線形振幅での閾値。
    public var thresholdAmplitude: Float {
        Float(pow(10, thresholdDB / 20))
    }

    /// 残すフレーム範囲を返す。
    /// - blockLevels: ブロックごとの RMS（先頭から順、線形 0〜1）
    /// - framesPerBlock: 1ブロックのフレーム数
    /// - totalFrames: 録音全体のフレーム数（最後のブロックは端数のことがある）
    /// - sampleRate: 秒→フレーム換算に使う
    /// 音声区間が見つからないときは何も切らず全体を返す（誤って空ファイルにしない）。
    public func trimRange(
        blockLevels: [Float], framesPerBlock: Int, totalFrames: Int, sampleRate: Double
    ) -> Range<Int> {
        let full = 0..<max(totalFrames, 0)
        guard totalFrames > 0, framesPerBlock > 0, !blockLevels.isEmpty else { return full }
        let threshold = thresholdAmplitude
        let blockSeconds = Double(framesPerBlock) / sampleRate
        let minRun = max(1, Int((minimumSpeech / blockSeconds).rounded(.up)))

        // 閾値以上が minRun ブロック以上続く「音声の山」の最初と最後を探す。
        var firstSpeech: Int?
        var lastSpeechEnd: Int?  // 山の末尾ブロックの次
        var runStart: Int?
        for (i, level) in blockLevels.enumerated() {
            if level >= threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if i - s >= minRun {
                    if firstSpeech == nil { firstSpeech = s }
                    lastSpeechEnd = i
                }
                runStart = nil
            }
        }
        if let s = runStart, blockLevels.count - s >= minRun {
            if firstSpeech == nil { firstSpeech = s }
            lastSpeechEnd = blockLevels.count
        }
        guard let firstSpeech, let lastSpeechEnd else { return full }

        let pad = Int((padding * sampleRate).rounded())
        let start = max(0, firstSpeech * framesPerBlock - pad)
        let end = min(totalFrames, lastSpeechEnd * framesPerBlock + pad)
        guard start < end else { return full }
        return start..<end
    }
}
