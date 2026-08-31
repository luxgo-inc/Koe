import Testing
@testable import KoeCore

@Suite struct ClipboardRestorePolicyTests {
    @Test func 自分のセット以降変化がなければ復元する() {
        #expect(ClipboardRestorePolicy.shouldRestore(changeCountAfterOurSet: 5, currentChangeCount: 5, hasSavedItems: true))
    }
    @Test func 他者が書き込んでいたら復元しない() {
        #expect(!ClipboardRestorePolicy.shouldRestore(changeCountAfterOurSet: 5, currentChangeCount: 7, hasSavedItems: true))
    }
    @Test func 退避データが空なら復元しない() {
        #expect(!ClipboardRestorePolicy.shouldRestore(changeCountAfterOurSet: 5, currentChangeCount: 5, hasSavedItems: false))
    }
}
