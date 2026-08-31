import AVFoundation
import Speech

// マイクから10秒録音して日本語認識し、volatile/final 結果と finalize 遅延を出力する。

// AVAudioEngine のタップコールバックはリアルタイムオーディオスレッドから呼ばれるため、
// MainActor など何らかのアクターに隔離されたクロージャ/型を渡すと Swift 6 の実行時
// isolation assertion でクラッシュする。この class 自体はどのアクターにも属さない
// （非アクター隔離）ので、そのメソッドを呼ぶだけの @Sendable クロージャは安全に
// リアルタイムスレッドから呼び出せる。
// @unchecked Sendable: converter (AVAudioConverter) はオーディオコールバックからの
// 単一直列呼び出し前提で Apple 側も想定しており、内部で保持する状態はこの process(_:)
// 呼び出し内で閉じているため手動で Sendable を保証する。
final class AudioPipe: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let analysisFormat: AVAudioFormat
    private let micFormat: AVAudioFormat
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

    init(
        converter: AVAudioConverter,
        analysisFormat: AVAudioFormat,
        micFormat: AVAudioFormat,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.converter = converter
        self.analysisFormat = analysisFormat
        self.micFormat = micFormat
        self.inputBuilder = inputBuilder
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = analysisFormat.sampleRate / micFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: capacity) else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: out))
        }
    }
}

@main
struct SpikeSpeech {
    static func main() async throws {
        let locale = Locale(identifier: "ja-JP")
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            print("ja-JP は SpeechTranscriber 非対応"); exit(1)
        }
        print("supported locale: \(supported.identifier)")

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("モデルをダウンロード中…")
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            print("bestAvailableAudioFormat が取れない"); exit(1)
        }
        print("analysis format: \(analysisFormat)")

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        let resultsTask = Task {
            var finalText = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalText += text
                        print("[final @\(Date().timeIntervalSince1970)] \(text)")
                    } else {
                        print("[volatile] \(text)")
                    }
                }
            } catch { print("results error: \(error)") }
            return finalText
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: analysisFormat) else {
            print("converter 作成失敗"); exit(1)
        }

        // installTap のクロージャは @main static func 内で生成されるため Swift 6 では MainActor 隔離が
        // 推論される。しかし AVAudioEngine はこのクロージャを realtime オーディオスレッドから直接呼び出すため、
        // MainActor 隔離クロージャを渡すと実行時に isolation assertion（dispatch_assert_queue_fail）で
        // クラッシュする。対策として変換ロジックを非アクター隔離の final class に切り出し、
        // installTap には @Sendable かつ MainActor に紐付かないクロージャを渡す。
        let pipe = AudioPipe(converter: converter, analysisFormat: analysisFormat, micFormat: micFormat, inputBuilder: inputBuilder)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
            pipe.process(buffer)
        }
        try engine.start()
        print("=== 10秒間、日本語で話してください（途中に英単語も混ぜること） ===")
        try await Task.sleep(for: .seconds(10))

        engine.stop()
        input.removeTap(onBus: 0)
        let t0 = Date()
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let finalizeMs = Date().timeIntervalSince(t0) * 1000
        let finalText = await resultsTask.value
        print("=== finalize 遅延: \(Int(finalizeMs))ms ===")
        print("=== 確定テキスト: \(finalText) ===")
    }
}
