import AVFoundation

public struct TranscriptUpdate: Sendable {
    /// 確定済みテキスト＋現在の volatile 部分を結合した「現時点の全文」
    public let displayText: String
    /// この更新で新たに確定したセグメント（volatile 更新時は nil）。
    /// 会議モードが話者別タイムスタンプ付き議事録を組み立てるために使う。
    public let finalizedSegment: String?

    public init(displayText: String, finalizedSegment: String? = nil) {
        self.displayText = displayText
        self.finalizedSegment = finalizedSegment
    }
}

/// STT エンジンの抽象。将来 whisper.cpp を追加する場合はこれに準拠させる。
public protocol TranscriptionEngine: AnyObject {
    /// モデルの確認・ダウンロード・予熱。アプリ起動時に一度呼ぶ。
    func prepare() async throws
    /// 認識セッションを開始し、途中経過のストリームを返す。
    func startSession() async throws -> AsyncStream<TranscriptUpdate>
    /// 音声バッファを供給する（AudioRecorder のタップから呼ばれる）。
    func feed(_ buffer: AVAudioPCMBuffer)
    /// 入力を締めて finalize し、確定全文を返す。
    func finishAndTranscript() async throws -> String
    /// セッションを破棄する（Esc キャンセル用）。結果は捨てる。
    func cancelSession() async
}
