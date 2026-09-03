import SwiftUI

struct RecordView: View {
    @Bindable var session: MeetingSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)

                if session.isRecording, let start = session.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(elapsedString(from: start, to: context.date))
                            .font(.system(size: 44, weight: .medium, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                    LevelMeter(level: session.level)
                        .frame(height: 6)
                        .padding(.horizontal, 48)
                } else if session.isPreparing {
                    ProgressView("音声認識モデルを準備中…（初回はダウンロードがあります）")
                } else if session.isFinishing {
                    ProgressView(session.finishingStatus.isEmpty ? "保存中…" : session.finishingStatus)
                } else {
                    Text("ボタンを押すと録音と文字起こしを開始します")
                        .foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.liveText.isEmpty ? " " : session.liveText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .id("live")
                    }
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: session.liveText) {
                        proxy.scrollTo("live", anchor: .bottom)
                    }
                }
                .padding(.horizontal)

                if let error = session.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Button {
                    Task {
                        if session.isRecording {
                            await session.stopAndSave()
                        } else {
                            await session.start()
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(session.isRecording ? Color.red.opacity(0.15) : Color.red)
                            .frame(width: 84, height: 84)
                        if session.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .disabled(session.isFinishing || session.isPreparing)
                .padding(.bottom, 8)

                if session.isRecording {
                    Text("画面をロックしても録音は続きます（最長3時間で自動停止）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .navigationTitle("Koe")
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.red)
                    .frame(width: geo.size.width * CGFloat(max(0.02, level)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
