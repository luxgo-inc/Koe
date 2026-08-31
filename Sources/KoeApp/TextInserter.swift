import AppKit
import CoreGraphics
import KoeCore

/// クリップボード退避 → テキストセット → Cmd+V 合成 → 条件つき復元。
/// スペックの「クリップボード退避・復元の仕様」を実装する。
@MainActor
final class TextInserter {
    /// 挿入を試み、Cmd+V を送信できたか（挿入成功の保証ではない）を返す。
    /// targetApp: 録音開始時のフロントアプリ。現フロントと違う場合は再アクティブ化を試みる。
    func insert(_ text: String, targetApp: NSRunningApplication?) async -> Bool {
        // 挿入先が変わっていたら戻す（失敗しても現フロントに挿入して続行）
        if let targetApp, NSWorkspace.shared.frontmostApplication != targetApp {
            targetApp.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }

        let pb = NSPasteboard.general
        // 全アイテム・全タイプ退避。promised data（data が nil）はスキップ。
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var copied = false
            for t in item.types {
                if let d = item.data(forType: t) {
                    copy.setData(d, forType: t)
                    copied = true
                }
            }
            return copied ? copy : nil
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        let countAfterSet = pb.changeCount

        guard postCmdV() else {
            // 送信失敗: 認識文をクリップボードに残したまま false（呼び出し側が通知）
            return false
        }

        try? await Task.sleep(for: .milliseconds(600))
        if ClipboardRestorePolicy.shouldRestore(
            changeCountAfterOurSet: countAfterSet,
            currentChangeCount: pb.changeCount,
            hasSavedItems: !saved.isEmpty
        ) {
            pb.clearContents()
            pb.writeObjects(saved)
        }
        return true
    }

    private func postCmdV() -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return false }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        return true
    }
}
