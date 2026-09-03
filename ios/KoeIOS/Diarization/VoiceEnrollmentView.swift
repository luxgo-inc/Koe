import AVFoundation
import KoeDiarization
import KoeKit
import SwiftUI

/// 自分の声紋登録画面。15秒ほど話してもらい、FluidAudio で 256 次元の声紋を抽出・保存する。
/// 登録済みなら会議録音の話者分離で「自分」と自動ラベル付けされる。
struct VoiceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var secondsLeft = recordSeconds
    @State private var message: String?
    @State private var recorder = AudioRecorder()
    @State private var writer: DiarizationAudioWriter?
    @State private var timerTask: Task<Void, Never>?

    private static let recordSeconds = 15
    private let audioSession = AudioSessionController()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("自分の声を登録")
                .font(.title2.bold())
            Text("録音開始後、\(Self.recordSeconds)秒ほど普段の調子で話し続けてください。\n（例: 今日の予定や自己紹介など、内容は保存されません）")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isRecording {
                Text("残り \(secondsLeft) 秒")
                    .font(.system(size: 36, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
            } else if isProcessing {
                ProgressView("声紋を抽出中…（初回はモデルのダウンロードがあります）")
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(message.contains("完了") ? .green : .red)
                    .multilineTextAlignment(.center)
            }

            Button(isRecording ? "録音中…" : "録音を開始") {
                Task { await startEnrollment() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRecording || isProcessing)
        }
        .padding()
        .onDisappear {
            timerTask?.cancel()
            recorder.stop()
            writer?.discard()
            audioSession.deactivate()
        }
    }

    private func startEnrollment() async {
        message = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "マイクの使用が許可されていません"
            return
        }
        do {
            try audioSession.activate()
            let w = DiarizationAudioWriter()
            try w.start()
            writer = w
            recorder.onBuffer = { @Sendable buffer in w.append(buffer) }
            try recorder.start()
            isRecording = true
            secondsLeft = Self.recordSeconds

            timerTask = Task {
                for remaining in (0..<Self.recordSeconds).reversed() {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    secondsLeft = remaining
                }
                await finishEnrollment()
            }
        } catch {
            message = "録音を開始できませんでした: \(error.localizedDescription)"
            audioSession.deactivate()
        }
    }

    private func finishEnrollment() async {
        recorder.onBuffer = nil
        recorder.stop()
        audioSession.deactivate()
        isRecording = false
        isProcessing = true
        defer { isProcessing = false }

        guard let writer else { return }
        let url = writer.finish()
        self.writer = nil
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let data = try Data(contentsOf: url)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            try await DiarizationService.shared.enrollSelf(samples: samples)
            message = "登録完了。以後の録音で「自分」の発言が自動識別されます。"
            try? await Task.sleep(for: .seconds(2))
            dismiss()
        } catch {
            message = "声紋の抽出に失敗しました: \(error.localizedDescription)"
        }
    }
}
