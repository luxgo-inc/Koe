import Testing
@testable import KoeCore

@Suite struct MeetingTranscriptTests {
    @Test func 空のビルダーはisEmpty() {
        let b = MeetingTranscriptBuilder()
        #expect(b.isEmpty)
    }

    @Test func セグメントを時刻順にマージしてMarkdown描画する() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 65, text: "こんにちは")
        b.add(speaker: "相手", seconds: 3, text: "本日はよろしくお願いします")
        let md = b.renderMarkdown(title: "テスト会議")
        #expect(md == """
        # テスト会議

        - [00:03] **相手**: 本日はよろしくお願いします
        - [01:05] **自分**: こんにちは

        """)
    }

    @Test func 空白のみのテキストは無視する() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 0, text: "  \n ")
        #expect(b.isEmpty)
    }

    @Test func 同時刻セグメントは追加順を保つ() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 5, text: "A")
        b.add(speaker: "相手", seconds: 5, text: "B")
        let md = b.renderMarkdown(title: "t")
        #expect(md.range(of: "A")!.lowerBound < md.range(of: "B")!.lowerBound)
    }

    @Test func 一時間超はhmmss表記() {
        #expect(MeetingTranscriptBuilder.timestamp(3725) == "1:02:05")
        #expect(MeetingTranscriptBuilder.timestamp(59) == "00:59")
    }

    @Test func 全文テキストは話者名なしで結合する() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 10, text: "後半")
        b.add(speaker: "相手", seconds: 2, text: "前半")
        #expect(b.plainText() == "相手: 前半\n自分: 後半")
    }
}
