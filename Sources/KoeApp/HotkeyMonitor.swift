import AppKit
import CoreGraphics
import KoeCore

/// CGEventTap によるホットキー監視（active tap）。
/// - コールバック内では判定と転送のみ（.tapDisabledByTimeout 対策）
/// - key repeat は除外
/// - Esc は shouldConsumeEscape() が true のときだけ消費
/// - tap 無効化（timeout / userInput）・スリープ復帰で自動再生成
final class HotkeyMonitor {
    struct Config {
        var rawKeyCode: Int64      // F9=101
        var refinedKeyCode: Int64  // F10=109
    }

    private static let escKeyCode: Int64 = 53

    var config: Config
    /// (mode, isDown, timestamp) 。メインスレッドに転送済み。
    var onHotkey: (@Sendable (RecordingMode, Bool, Double) -> Void)?
    var onEscape: (@Sendable () -> Void)?
    /// idle 中に Esc を握り潰さないための状態問い合わせ
    var shouldConsumeEscape: @Sendable () -> Bool = { false }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var sleepObserver: NSObjectProtocol?

    init(config: Config) {
        self.config = config
    }

    /// 監視開始。入力監視権限が無ければ false。
    @discardableResult
    func start() -> Bool {
        stop()
        guard CGPreflightListenEventAccess() else { return false }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        nonisolated(unsafe) let unmanagedSelf = Unmanaged.passUnretained(self)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            unmanagedSelf.takeUnretainedValue().start()  // スリープ復帰で tap 再生成
        }
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        tap = nil
        runLoopSource = nil
        sleepObserver = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // tap が無効化されたら再有効化
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
        if isRepeat, code == config.rawKeyCode || code == config.refinedKeyCode {
            return nil  // repeat は消費して無視
        }
        let isDown = type == .keyDown
        let now = Date().timeIntervalSince1970

        if code == config.rawKeyCode || code == config.refinedKeyCode {
            let mode: RecordingMode = code == config.rawKeyCode ? .raw : .refined
            if let callback = onHotkey {
                DispatchQueue.main.async {
                    callback(mode, isDown, now)
                }
            }
            return nil  // 消費
        }
        if code == Self.escKeyCode, isDown, shouldConsumeEscape() {
            if let callback = onEscape {
                DispatchQueue.main.async {
                    callback()
                }
            }
            return nil  // 録音中のみ消費
        }
        return Unmanaged.passUnretained(event)
    }
}
