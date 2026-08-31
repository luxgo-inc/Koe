import AVFoundation
import Speech

// マイクから10秒録音して日本語認識し、volatile/final 結果と finalize 遅延を出力する。

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

        // Swift 6 の厳格な並行性チェック対策: AVAudioEngine のタップコールバックは @Sendable クロージャとして
        // 実行されるが、内部で使う AVAudioPCMBuffer（buffer/out）や var fed は Sendable/並行安全性の
        // 静的チェックに引っかかり warning が出る（error ではなくビルドは成功する）。タップコールバックは
        // AVAudioEngine 内部の単一の直列キューから順番に呼ばれ、これらの値はコールバック内でのみ
        // 生成・使用されるため実際には安全。ここでは warning を許容し、挙動を変えるラップは行わない。
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
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
