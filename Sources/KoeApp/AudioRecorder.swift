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
    /// タップは張ったまま「録音中だけ」バッファを配送するためのゲート。
    /// オーディオスレッドから読むためロックで保護する。
    private let deliveryLock = NSLock()
    private var _delivering = false
    private var isDelivering: Bool {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        return _delivering
    }
    private func setDelivering(_ value: Bool) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        _delivering = value
    }

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onDeviceChange: (() -> Void)?   // .main キューで配送されるのでそのままで良い

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// 起動時に一度呼ぶ。inputNode の初回アクセス（HAL/デバイス初期化）と
    /// AVAudioEngine の内部リソース確保を前倒しし、start() の所要時間を短くする。
    /// IO は開始しないため、マイクインジケータは点灯しない。
    func prewarm() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    /// 録音開始。キープアライブ中（pause() 後で engine がまだ回っている状態）なら
    /// デバイス起動を待たずに即座に再開する。
    func start() throws {
        setDelivering(true)
        if engine.isRunning, observer != nil { return }
        // 中途半端な状態（tap や observer だけ残っている）なら畳んでから張り直す
        if observer != nil {
            stop()
            setDelivering(true)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // belt-and-braces: このクロージャは nonisolated なメソッド内で生成されるため
        // MainActor 推論は本来発生しないが、docs/spike-results.md スパイクB の教訓を
        // コードで明示するため @Sendable を明記しておく。
        // bufferSize は「1コールバックあたりのフレーム数」。4096 だと 48kHz で 85ms 分
        // 溜まるまで最初のバッファが届かないため、1024（約21ms）にして初動を早める。
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            guard let self, self.isDelivering else { return }
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
            setDelivering(false)
            throw error
        }
    }

    /// 配送だけ止めて engine は回したままにする（キープアライブ）。
    /// 次の start() が CoreAudio のデバイス起動（実測 約100ms＋最初のバッファまで100-250ms）を
    /// 払わずに済む。マイクインジケータは点灯したままなので、呼び出し側が一定時間後に
    /// stop() まで落とすこと。
    func pause() {
        setDelivering(false)
    }

    /// engine ごと完全に停止する。
    func stop() {
        setDelivering(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// キープアライブ中かどうか（engine は回っているが配送は止まっている）。
    var isKeptAlive: Bool { engine.isRunning && !isDelivering }

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
