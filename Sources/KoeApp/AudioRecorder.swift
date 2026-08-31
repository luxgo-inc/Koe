import AVFoundation

/// AVAudioEngine のマイクキャプチャ。バッファは onBuffer、音量レベル（0-1）は onLevel に流す。
/// デバイス切断は AVAudioEngineConfigurationChange 通知で検出し onDeviceChange を呼ぶ。
///
/// 注意: onBuffer / onLevel はリアルタイムオーディオスレッドから呼ばれるため
/// @Sendable の非 MainActor クロージャに限定している（MainActor 推論の閉包を
/// 誤って割り当てると dispatch_assert_queue_fail でクラッシュする。
/// docs/spike-results.md スパイクB 参照）。
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onDeviceChange: (() -> Void)?   // .main キューで配送されるのでそのままで良い

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start() throws {
        // 再入時は idempotent に再起動する（前回の tap / observer が残っていれば止めてから張り直す）
        if observer != nil {
            stop()
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // belt-and-braces: このクロージャは nonisolated なメソッド内で生成されるため
        // MainActor 推論は本来発生しないが、docs/spike-results.md スパイクB の教訓を
        // コードで明示するため @Sendable を明記しておく。
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            self.onLevel?(Self.rmsLevel(buffer))
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onDeviceChange?()
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        // -50dB〜0dB を 0〜1 に正規化
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }
}
