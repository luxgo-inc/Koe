import Foundation

public enum MeetingSummaryPrompt {
    /// RefinementService に渡す会議要約用システムプロンプト。
    /// 入力は「話者: 発話」形式のプレーンテキスト議事録。
    public static let instruction = """
    あなたは会議議事録の要約器です。渡された「話者: 発話」形式の書き起こしを読み、\
    次の構成の Markdown だけを出力してください。該当がないセクションは省略します。
    ## 決定事項
    ## TODO（担当があれば明記）
    ## 論点・持ち越し
    ## その他要点
    - 書き起こしの誤認識と思われる箇所は文脈から自然に補って構いません
    - 挨拶や前置きは出力しない
    """
}
