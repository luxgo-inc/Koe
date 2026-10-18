import AVFoundation
import KoeObjC
#if os(macOS)
import CoreAudio
#endif

/// AVAudioEngine のマイクキャプチャ。バッファは onBuffer、音量レベル（0-1）は onLevel に流す。
/// デバイス切断は AVAudioEngineConfigurationChange 通知で検出し onDeviceChange を呼ぶ。
///
/// 注意: onBuffer / onLevel はリアルタイムオーディオスレッドから呼ばれるため
/// @Sendable の非 MainActor クロージャに限定している（MainActor 推論の閉包を
/// 誤って割り当てると dispatch_assert_queue_fail でクラッシュする。
/// docs/spike-results.md スパイクB 参照）。
public final class AudioRecorder: @unchecked Sendable {
    public init() {}

    public enum RecorderError: LocalizedError {
        /// 入力デバイスが無い・まだ準備できていない（サンプルレート/チャンネル数が0）。
        case inputUnavailable
        public var errorDescription: String? {
            switch self {
            case .inputUnavailable: "入力マイクが見つかりません"
            }
        }
    }

    /// デバイス変更後に古いフォーマットを抱えた engine は作り直すため var。
    /// MainActor（呼び出し側）からのみ触る。タップのクロージャは engine を参照しない。
    private var engine = AVAudioEngine()
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

    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onDeviceChange: (() -> Void)?   // .main キューで配送されるのでそのままで良い
    /// システムデフォルト入力デバイスの変更通知（.main キューで配送）。
    /// AVAudioEngineConfigurationChange と違い、engine が完全停止しているアイドル中でも届く。
    public var onDefaultInputDeviceChange: (() -> Void)?

    public var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    #if os(macOS)
    /// 現在のシステムデフォルト入力デバイス名（AVAudioEngine はデフォルト入力を使うため、
    /// これが実際に録音へ使われるマイク）。イヤホンを挿しただけで「外部マイク」（3.5mm ジャック）へ
    /// 静かに切り替わり認識精度が落ちる事故があるので、HUD 表示・変更通知の材料にする。
    public var inputDeviceName: String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown else { return nil }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }
    /// デフォルト入力デバイスの常時監視を開始する（アプリ生存中は解除しない）。
    /// engine 停止中のアイドル時にデバイスが替わると、engine は古いデバイス構成を抱えたまま
    /// になり、次の start() 直後に構成変更が飛んで初回録音が壊れる。それを防ぐため、
    /// 呼び出し側はこの通知で engine を畳んで prewarm() し直すこと。
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    public func startObservingDefaultInputDevice() {
        guard defaultDeviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultInputDeviceChange?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        if status == noErr { defaultDeviceListener = block }
    }

    /// システムデフォルト入力デバイスの実サンプルレート（取得できなければ nil）。
    static var defaultInputSampleRate: Double? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown else { return nil }
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }
    #endif

    /// 起動時に一度呼ぶ。inputNode の初回アクセス（HAL/デバイス初期化）と
    /// AVAudioEngine の内部リソース確保を前倒しし、start() の所要時間を短くする。
    /// IO は開始しないため、マイクインジケータは点灯しない。
    public func prewarm() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        do {
            try KoeObjCException.catching { self.engine.prepare() }
        } catch {
            KoeLog.error("AudioRecorder.prewarm: prepare が例外: \(error.localizedDescription)")
        }
    }

    /// engine を完全に停止して新しいインスタンスに作り直す。
    /// AVAudioEngine は inputNode のフォーマットをキャッシュするため、入力デバイスが
    /// 替わった後（とくにサンプルレートが違うデバイス: AirPods 等）も古い値を返し続け、
    /// そのまま installTap すると「format.sampleRate == inputHWFormat.sampleRate」の
    /// NSException になる（2026-10-16/18 のクラッシュ原因）。デバイス変更時はこれを呼ぶ。
    public func reset() {
        stop()
        engine = AVAudioEngine()
    }

    /// 録音開始。キープアライブ中（pause() 後で engine がまだ回っている状態）なら
    /// デバイス起動を待たずに即座に再開する。
    /// 戻り値は実際にタップへ使ったフォーマット。engine を作り直した場合は事前に
    /// `inputFormat` で読んだ値と変わり得るので、呼び出し側は変換設定をこれに合わせること。
    @discardableResult
    public func start() throws -> AVAudioFormat {
        setDelivering(true)
        if engine.isRunning, observer != nil { return inputFormat }
        // 中途半端な状態（tap や observer だけ残っている）なら畳んでから張り直す
        if observer != nil {
            stop()
            setDelivering(true)
        }
        #if os(macOS)
        // デバイス変更通知の取りこぼし（通知処理より先にホットキーが押された等）に備え、
        // engine の把握しているレートが実デバイスとずれていたら先に作り直す。
        if let hw = Self.defaultInputSampleRate,
           abs(engine.inputNode.outputFormat(forBus: 0).sampleRate - hw) > 0.5 {
            KoeLog.info("AudioRecorder.start: engineのフォーマットが実デバイス(\(hw)Hz)と不一致のため作り直す")
            reset()
            setDelivering(true)
        }
        #endif
        do {
            return try installTapAndStart()
        } catch {
            // NSException（フォーマット不一致など）か engine.start() の失敗。
            // engine を作り直して1回だけ再試行する。
            KoeLog.error("AudioRecorder.start: 失敗→engineを作り直して再試行: \(error.localizedDescription)")
            reset()
            setDelivering(true)
            do {
                return try installTapAndStart()
            } catch {
                KoeLog.error("AudioRecorder.start: 再試行も失敗: \(error.localizedDescription)")
                setDelivering(false)
                throw error
            }
        }
    }

    private func installTapAndStart() throws -> AVAudioFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        // installTap / engine.start は条件違反を NSException で投げる。Swift では捕まえられず、
        // AppKit が握りつぶすと Swift Concurrency の状態が壊れて後で SIGSEGV になるため、
        // 必ず KoeObjCException 越しに呼ぶ。
        // belt-and-braces: このクロージャは nonisolated なメソッド内で生成されるため
        // MainActor 推論は本来発生しないが、docs/spike-results.md スパイクB の教訓を
        // コードで明示するため @Sendable を明記しておく。
        // bufferSize は「1コールバックあたりのフレーム数」。4096 だと 48kHz で 85ms 分
        // 溜まるまで最初のバッファが届かないため、1024（約21ms）にして初動を早める。
        try KoeObjCException.catching {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                guard let self, self.isDelivering else { return }
                self.onBuffer?(buffer)
                self.onLevel?(Self.rmsLevel(buffer))
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onDeviceChange?()
        }
        do {
            var startError: Error?
            try KoeObjCException.catching {
                do { try self.engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            try? KoeObjCException.catching { input.removeTap(onBus: 0) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw error
        }
        return format
    }

    /// 配送だけ止めて engine は回したままにする（キープアライブ）。
    /// 次の start() が CoreAudio のデバイス起動（実測 約100ms＋最初のバッファまで100-250ms）を
    /// 払わずに済む。マイクインジケータは点灯したままなので、呼び出し側が一定時間後に
    /// stop() まで落とすこと。
    public func pause() {
        setDelivering(false)
    }

    /// engine ごと完全に停止する。
    public func stop() {
        setDelivering(false)
        do {
            try KoeObjCException.catching {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }
        } catch {
            KoeLog.error("AudioRecorder.stop: 例外: \(error.localizedDescription)")
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// キープアライブ中かどうか（engine は回っているが配送は止まっている）。
    public var isKeptAlive: Bool { engine.isRunning && !isDelivering }

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
