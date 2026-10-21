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

    /// タップに使う（＝ onBuffer に届く）フォーマット。
    public var inputFormat: AVAudioFormat {
        Self.tapFormat(for: inputNode)
    }

    /// 入力ノードの出力側フォーマットは engine 生成時のデバイスのものがキャッシュされ、
    /// 入力デバイスが替わる（固定マイクへの差し替え、デバイス変更）と実デバイスの
    /// レートとずれることがある。ずれたまま installTap すると、レートが合わない
    /// 例外（2026-10-16/18 のクラッシュ）になるか、例外にならなくてもバッファが1つも
    /// 届かない（Studio Display マイク 44.1kHz で実測）。ハードウェア側（入力側）の
    /// レートでタップを張れば正しく届くため、ずれているときはそちらに合わせる。
    private static func tapFormat(for node: AVAudioInputNode) -> AVAudioFormat {
        let output = node.outputFormat(forBus: 0)
        let hardware = node.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, abs(hardware.sampleRate - output.sampleRate) > 0.5,
              let adjusted = AVAudioFormat(
                standardFormatWithSampleRate: hardware.sampleRate,
                channels: max(output.channelCount, 1))
        else { return output }
        return adjusted
    }

    /// engine.inputNode の代わりに必ずこれを使う（固定マイクの適用を先に済ませるため）。
    private var inputNode: AVAudioInputNode {
        #if os(macOS)
        applyPreferredDeviceIfNeeded()
        #endif
        return engine.inputNode
    }

    #if os(macOS)
    public struct InputDevice: Identifiable, Hashable, Sendable {
        public let uid: String
        public let name: String
        public var id: String { uid }
    }

    /// 録音に使うマイクの UID（nil = システムのデフォルト入力に従う）。
    /// 変更は次に engine を作り直したとき（reset()）に反映される。アイドル中なら即座に作り直し、
    /// 録音中なら次の start() で作り直す（キープアライブの engine を使い回さない）。
    public private(set) var preferredInputDeviceUID: String?
    public func setPreferredInputDevice(uid: String?) {
        guard uid != preferredInputDeviceUID else { return }
        preferredInputDeviceUID = uid
        if isDelivering {
            needsResetForDeviceChange = true
        } else {
            reset()
        }
    }

    /// 録音中にマイク指定が変わり、engine の作り直しを次の start() まで持ち越しているか。
    private var needsResetForDeviceChange = false

    /// いまの engine に固定マイクを適用済みか（engine を作り直すたびに false に戻る）。
    private var preferredDeviceApplied = false
    /// 固定マイクを実際に使えているか（未接続でデフォルトにフォールバック中なら false）。
    public private(set) var isUsingPreferredDevice = false

    /// AVAudioEngine の入力は既定でシステムのデフォルト入力に追従するため、
    /// 入力 AU の CurrentDevice を差し替えて固定マイクを使わせる。
    /// フォーマットを読む・タップを張る前（engine を作り直した直後）に1回だけ行う。
    private func applyPreferredDeviceIfNeeded() {
        guard !preferredDeviceApplied else { return }
        preferredDeviceApplied = true
        isUsingPreferredDevice = false
        guard let uid = preferredInputDeviceUID else { return }
        guard let deviceID = Self.inputDevices().first(where: { $0.uid == uid })?.deviceID else {
            KoeLog.info("固定マイク(\(uid))が未接続のためデフォルト入力を使う")
            return
        }
        guard let unit = engine.inputNode.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        isUsingPreferredDevice = status == noErr
        if status != noErr { KoeLog.error("固定マイクの適用に失敗: OSStatus \(status)") }
    }

    /// 接続中の入力デバイス一覧（設定画面の選択肢用）。
    public static func availableInputDevices() -> [InputDevice] {
        inputDevices().map { InputDevice(uid: $0.uid, name: $0.name) }
    }

    private static func inputDevices() -> [(deviceID: AudioDeviceID, uid: String, name: String)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return (id, uid, name)
        }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static var defaultInputDeviceID: AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// 実際に録音へ使われる（使われる予定の）デバイス。固定マイクが接続中ならそれ、
    /// そうでなければシステムのデフォルト入力。
    private var effectiveInputDeviceID: AudioDeviceID? {
        if let uid = preferredInputDeviceUID,
           let pinned = Self.inputDevices().first(where: { $0.uid == uid }) {
            return pinned.deviceID
        }
        return Self.defaultInputDeviceID
    }

    /// 録音に使われる入力デバイス名。イヤホンを挿しただけで「外部マイク」（3.5mm ジャック）へ
    /// 静かに切り替わり認識精度が落ちる事故があるので、HUD 表示・変更通知の材料にする。
    public var inputDeviceName: String? {
        effectiveInputDeviceID.flatMap { Self.stringProperty($0, kAudioObjectPropertyName) }
    }

    /// 固定マイクが設定されているのに未接続か（呼び出し側の通知用）。
    public var isPreferredDeviceMissing: Bool {
        guard let uid = preferredInputDeviceUID else { return false }
        return !Self.inputDevices().contains { $0.uid == uid }
    }

    /// デフォルト入力デバイスの変更と、デバイスの抜き差しの常時監視を開始する
    /// （アプリ生存中は解除しない）。どちらも onDefaultInputDeviceChange で通知する。
    /// engine 停止中のアイドル時にデバイスが替わると、engine は古いデバイス構成を抱えたまま
    /// になり、次の start() で壊れる。それを防ぐため、呼び出し側はこの通知で reset() して
    /// prewarm() し直すこと。抜き差しの監視は、固定マイク（有線マイク等）を後から
    /// 挿したときに掴み直すため。
    private var deviceListeners: [AudioObjectPropertyListenerBlock] = []
    public func startObservingDefaultInputDevice() {
        guard deviceListeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onDefaultInputDeviceChange?()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
            if status == noErr { deviceListeners.append(block) }
        }
    }

    #endif

    /// 起動時に一度呼ぶ。inputNode の初回アクセス（HAL/デバイス初期化）と
    /// AVAudioEngine の内部リソース確保を前倒しし、start() の所要時間を短くする。
    /// IO は開始しないため、マイクインジケータは点灯しない。
    public func prewarm() {
        _ = inputNode.outputFormat(forBus: 0)
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
        #if os(macOS)
        preferredDeviceApplied = false
        needsResetForDeviceChange = false
        #endif
    }

    /// 録音開始。キープアライブ中（pause() 後で engine がまだ回っている状態）なら
    /// デバイス起動を待たずに即座に再開する。
    /// 戻り値は実際にタップへ使ったフォーマット。engine を作り直した場合は事前に
    /// `inputFormat` で読んだ値と変わり得るので、呼び出し側は変換設定をこれに合わせること。
    @discardableResult
    public func start() throws -> AVAudioFormat {
        #if os(macOS)
        if needsResetForDeviceChange { reset() }
        #endif
        setDelivering(true)
        if engine.isRunning, observer != nil { return inputFormat }
        // 中途半端な状態（tap や observer だけ残っている）なら畳んでから張り直す
        if observer != nil {
            stop()
            setDelivering(true)
        }
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
        let input = inputNode
        let format = Self.tapFormat(for: input)
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
