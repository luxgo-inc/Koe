import AudioToolbox
import AVFoundation
import Foundation

// スパイクD: システム音声のプロセスタップ検証。
// 全プロセスのシステム出力をタップ→集約デバイス経由でIOProcに受け、
// 10秒間 1秒ごとに RMS レベルを表示する。音楽を再生しながら実行し、
// レベルが 0 以外で動くことを確認する。
// 注意: TCC「システム音声録音」プロンプトはターミナル（実行元）に対して出る。

@main
struct SpikeSystemAudio {
    static func main() throws {
        // 1. 全プロセス対象のタップを作成（除外リスト空 = 全部）
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "SpikeTap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { fatalError("tap creation failed: \(status)") }
        print("tap created: \(tapID)")

        // 2. タップのフォーマット取得
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            fatalError("format read failed: \(status)")
        }
        print("format: \(format)")

        // 3. タップを含む private 集約デバイスを作成
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpikeAgg",
            kAudioAggregateDeviceUIDKey: "jp.luxgo.koe.spike-agg",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard status == noErr else { fatalError("aggregate creation failed: \(status)") }
        print("aggregate created: \(aggID)")

        // 4. IOProc で受信、RMS を表示
        nonisolated(unsafe) var latestRMS: Float = 0
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { @Sendable _, inInputData, _, _, _ in
            let ablPointer = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let buf = ablPointer.first, let data = buf.mData else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { return }
            let samples = data.bindMemory(to: Float.self, capacity: n)
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            latestRMS = (sum / Float(n)).squareRoot()
        }
        guard status == noErr else { fatalError("ioproc failed: \(status)") }
        status = AudioDeviceStart(aggID, procID)
        guard status == noErr else { fatalError("start failed: \(status)") }

        print("capturing 10s... 音楽やYouTubeを再生してください")
        for i in 1...10 {
            Thread.sleep(forTimeInterval: 1)
            print("t=\(i)s rms=\(latestRMS)")
        }

        AudioDeviceStop(aggID, procID)
        if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
        print("done")
    }
}
