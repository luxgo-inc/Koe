/// クリップボード復元の可否判定。
/// 自分がテキストをセットした直後の changeCount と復元直前の changeCount が
/// 一致する場合のみ復元する（ユーザーや他アプリのコピーを上書きしない）。
public enum ClipboardRestorePolicy {
    public static func shouldRestore(
        changeCountAfterOurSet: Int,
        currentChangeCount: Int,
        hasSavedItems: Bool
    ) -> Bool {
        hasSavedItems && currentChangeCount == changeCountAfterOurSet
    }
}
