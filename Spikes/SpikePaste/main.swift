import AppKit
import CoreGraphics

// 実行後3秒以内に貼り付け先アプリをアクティブにする。
// クリップボード退避→テキストセット→Cmd+V→復元 まで一連を検証する。

let canPost = CGPreflightPostEventAccess()
print("post-event access preflight: \(canPost)")
if !canPost {
    _ = CGRequestPostEventAccess()
    print("権限許可後に再実行してください"); exit(1)
}

let pb = NSPasteboard.general
// 退避（全アイテム・全タイプ）
let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
    let copy = NSPasteboardItem()
    for t in item.types {
        if let d = item.data(forType: t) { copy.setData(d, forType: t) }
    }
    return copy
}
print("退避アイテム数: \(saved.count)")

print("3秒以内に貼り付け先をアクティブにしてください…")
Thread.sleep(forTimeInterval: 3)

pb.clearContents()
pb.setString("こんにちは、Koeのペーストテストです。", forType: .string)
let countAfterSet = pb.changeCount

let src = CGEventSource(stateID: .combinedSessionState)
let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)!
vDown.flags = .maskCommand
let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)!
vUp.flags = .maskCommand
vDown.post(tap: .cghidEventTap)
vUp.post(tap: .cghidEventTap)

Thread.sleep(forTimeInterval: 0.6)
if pb.changeCount == countAfterSet, !saved.isEmpty {
    pb.clearContents()
    pb.writeObjects(saved)
    print("クリップボード復元: 実施")
} else {
    print("クリップボード復元: スキップ (changeCount=\(pb.changeCount) vs \(countAfterSet), saved=\(saved.count))")
}
print("完了。貼り付け先を確認してください。")
