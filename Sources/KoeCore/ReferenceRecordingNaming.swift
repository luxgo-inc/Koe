import Foundation

/// 参考音声（短い発話を高音質 WAV として残す録音）のファイル名を決める。
/// `yyyyMMdd-HHmmss-<書き起こしの先頭12字程度>.wav`。ファイル名に使えない文字は除く。
public enum ReferenceRecordingNaming {
    public static let defaultMaxTranscriptChars = 12

    /// ファイル名に含めない文字: パス区切り・Windows でも不正な記号・制御文字。
    private static let forbidden: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\:*?\"<>|")
        set.formUnion(.controlCharacters)
        set.formUnion(.newlines)
        set.formUnion(.illegalCharacters)
        return set
    }()

    /// 書き起こしをファイル名用の断片にする。禁止文字を除き、空白は詰め、先頭 maxChars 字に切る。
    /// 末尾の句読点（「。」「、」など）は見た目のために落とす。
    public static func slug(from transcript: String, maxChars: Int = defaultMaxTranscriptChars) -> String {
        let cleaned = String(transcript.unicodeScalars.filter { !forbidden.contains($0) })
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined()
        let head = String(cleaned.prefix(maxChars))
        // 末尾の句読点・記号だけを落とす（「では、弾の間隔を広げると、」→「…広げると」）
        var scalars = Array(head.unicodeScalars)
        while let last = scalars.last, CharacterSet.punctuationCharacters.contains(last)
            || CharacterSet.symbols.contains(last) {
            scalars.removeLast()
        }
        var result = ""
        result.unicodeScalars.append(contentsOf: scalars)
        return result
    }

    /// 拡張子なしのベース名。書き起こしが空（または記号だけ）なら日時のみ。
    public static func baseName(
        date: Date, transcript: String, maxChars: Int = defaultMaxTranscriptChars,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let fragment = slug(from: transcript, maxChars: maxChars)
        return fragment.isEmpty ? stamp : "\(stamp)-\(fragment)"
    }

    /// 既存ファイルと衝突しないベース名を返す。衝突したら `-2`, `-3`… を付ける。
    /// `exists` には「そのベース名（拡張子なし）が使用済みか」を返すクロージャを渡す。
    public static func uniqueBaseName(_ base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
