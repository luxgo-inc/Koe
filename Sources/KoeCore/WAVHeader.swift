import Foundation

/// 無圧縮 PCM（整数）WAV の 44 バイトヘッダ。
public enum WAVHeader {
    public static let byteCount = 44

    /// - sampleRate: 例 48000
    /// - channels: 例 1
    /// - bitsPerSample: 16 または 24
    /// - dataByteCount: data チャンクのバイト数
    public static func make(sampleRate: Int, channels: Int, bitsPerSample: Int, dataByteCount: Int) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        var d = Data(capacity: byteCount)
        d.append(ascii: "RIFF")
        d.append(le32: UInt32(clamping: 36 + dataByteCount))
        d.append(ascii: "WAVE")
        d.append(ascii: "fmt ")
        d.append(le32: 16)                      // fmt チャンク長（PCM）
        d.append(le16: 1)                       // フォーマット: PCM 整数
        d.append(le16: UInt16(channels))
        d.append(le32: UInt32(sampleRate))
        d.append(le32: UInt32(byteRate))
        d.append(le16: UInt16(blockAlign))
        d.append(le16: UInt16(bitsPerSample))
        d.append(ascii: "data")
        d.append(le32: UInt32(clamping: dataByteCount))
        return d
    }
}

private extension Data {
    mutating func append(ascii s: String) { append(contentsOf: Array(s.utf8)) }
    mutating func append(le16 v: UInt16) { append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
    mutating func append(le32 v: UInt32) {
        append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }
}
