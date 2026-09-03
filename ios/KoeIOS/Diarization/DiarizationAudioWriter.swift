import AVFoundation
import Foundation

/// マイクバッファを 16kHz モノラル Float32 に変換して生バイナリファイルへ追記する。
/// 話者分離（FluidAudio）は 16kHz モノラルを要求するため、録音中に並行して蓄積しておき、
/// 停止時にファイルごと mmap してダイアライゼーションへ渡す（長時間録音でもメモリに乗せない）。
/// append() はリアルタイムオーディオスレッドから呼ばれるため、変換とI/Oは専用シリアルキューで行う。
final class DiarizationAudioWriter: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let queue = DispatchQueue(label: "jp.luxgo.koe.diarization-writer", qos: .utility)
    private var handle: FileHandle?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: DiarizationAudioWriter.sampleRate,
        channels: 1, interleaved: false)!
    let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-\(UUID().uuidString).f32")
    }

    func start() throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let handle else { return }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            }
            guard let converter else { return }
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var err: NSError?
            var fed = false
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
            handle.write(Data(bytes: data[0], count: Int(out.frameLength) * MemoryLayout<Float>.size))
        }
    }

    /// 書き込みを完了し、蓄積済みファイルの URL を返す。
    func finish() -> URL {
        queue.sync { [self] in
            try? handle?.close()
            handle = nil
            converter = nil
        }
        return fileURL
    }

    func discard() {
        _ = finish()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
