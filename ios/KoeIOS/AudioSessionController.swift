import AVFAudio
import Foundation

/// iOS の AVAudioSession 管理。録音カテゴリの有効化と、電話着信等の割り込みからの
/// 自動復帰を担う。Bluetooth 入力は有効にしない（HFP 8kHz マイクへ勝手にルートされて
/// 認識品質が崩壊するのを避け、内蔵マイク優先にする）。
@MainActor
final class AudioSessionController {
    /// 割り込み終了（shouldResume 付き）で呼ばれる。録音エンジンの再起動用。
    var onInterruptionEnded: (() -> Void)?
    private var observer: NSObjectProtocol?

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session, queue: .main
            ) { note in
                let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                MainActor.assumeIsolated {
                    guard let typeRaw,
                          AVAudioSession.InterruptionType(rawValue: typeRaw) == .ended,
                          let optionRaw,
                          AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume)
                    else { return }
                    AudioSessionHolder.current?.onInterruptionEnded?()
                }
            }
            AudioSessionHolder.current = self
        }
    }

    func deactivate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        AudioSessionHolder.current = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// NotificationCenter の @Sendable クロージャから weak self を安全に触るための退避先。
@MainActor
private enum AudioSessionHolder {
    weak static var current: AudioSessionController?
}
