import AppKit
import CoreGraphics

// F9=101, F10=109。ターミナルから実行し、F9/F10 を押して出力を確認する。
// ターミナル.app に「入力監視」権限が必要（初回実行時にプロンプトが出る）。

let granted = CGPreflightListenEventAccess()
print("listen-event access preflight: \(granted)")
if !granted {
    _ = CGRequestListenEventAccess()
    print("権限を許可してから再実行してください（システム設定 > プライバシーとセキュリティ > 入力監視）")
    exit(1)
}

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,          // active tap: nil を返すとイベントを消費する
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
        if code == 101 || code == 109 {
            let kind = type == .keyDown ? "DOWN" : "UP  "
            print("[captured] \(kind) keycode=\(code) repeat=\(isRepeat) ts=\(Date().timeIntervalSince1970)")
            return nil  // 消費: F10 のミュート等が発動しないことを確認する
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    print("tapCreate failed — 入力監視権限を確認してください")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("F9 / F10 を押してください（メディアキー設定のまま・Fn併用なしで）。Ctrl+C で終了。")
CFRunLoopRun()
