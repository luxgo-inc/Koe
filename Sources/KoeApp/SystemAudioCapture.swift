import AudioToolbox
import AVFoundation

/// Core Audio プロセスタップによるシステム再生音声のキャプチャ。
/// 全プロセスの出力をタップし、private 集約デバイスの IOProc で受けて
/// AVAudioPCMBuffer として onBuffer に流す。
///
/// 注意: onBuffer はリアルタイムオーディオスレッドから呼ばれるため
/// @Sendable の非 MainActor クロージャに限定する。IOProc ブロック自体にも
/// @Sendable 明示が必須（無いと MainActor 隔離推論で dispatch_assert_queue_fail
/// クラッシュ。docs/spike-results.md スパイクD 参照）。
/// タップのフォーマットは interleaved（マイクと異なる）だが、下流の
/// AVAudioConverter が吸収する。
/// TCC「システム音声録音」の許可が必要（Info.plist NSAudioCaptureUsageDescription）。
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    enum CaptureError: Error {
        case tapCreation(OSStatus)
        case formatRead(OSStatus)
        case aggregateCreation(OSStatus)
        case ioProc(OSStatus)
        case deviceStart(OSStatus)
    }

    func start() throws {
        stop()  // 再入時は掃除してから

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "KoeMeetingTap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw CaptureError.tapCreation(status) }
        tapID = tap

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            let s = status
            stop()
            throw CaptureError.formatRead(s)
        }
        format = fmt

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koe-MeetingCapture",
            kAudioAggregateDeviceUIDKey: "jp.luxgo.koe.meeting-agg",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard status == noErr else {
            let s = status
            stop()
            throw CaptureError.aggregateCreation(s)
        }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { @Sendable [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.format else { return }
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: UnsafeMutablePointer(mutating: inInputData),
                deallocator: nil) else { return }
            self.onBuffer?(pcm)
        }
        guard status == noErr, proc != nil else {
            let s = status
            stop()
            throw CaptureError.ioProc(s)
        }
        procID = proc

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            let s = status
            stop()
            throw CaptureError.deviceStart(s)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
    }
}
