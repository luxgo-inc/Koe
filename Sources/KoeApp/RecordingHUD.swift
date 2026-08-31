import AppKit
import KoeCore
import SwiftUI

/// 録音中の画面下部フローティング HUD。nonactivating NSPanel でフォーカスを奪わない。
@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?
    private let model = HUDModel()

    func show(mode: RecordingMode) {
        model.mode = mode
        model.phase = .recording
        model.level = 0
        model.levelHistory = []
        model.text = ""
        if panel == nil { panel = makePanel() }
        positionAtBottom()
        panel?.orderFrontRegardless()
    }

    func updateLevel(_ level: Float) {
        model.level = level
        model.levelHistory.append(level)
        if model.levelHistory.count > 40 {
            model.levelHistory.removeFirst()
        }
    }

    func updateText(_ text: String) { model.text = text }
    func showFinalizing() { model.phase = .finalizing }
    func showRefining() { model.phase = .refining }
    func hide() { panel?.orderOut(nil) }

    func showInserted() {
        model.phase = .inserted
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if model.phase == .inserted { hide() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 88),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private func positionAtBottom() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 24))
    }
}

@MainActor
@Observable
final class HUDModel {
    enum Phase { case recording, finalizing, refining, inserted }
    var mode: RecordingMode = .raw
    var phase: Phase = .recording
    var level: Float = 0
    var levelHistory: [Float] = []
    var text = ""
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        if model.phase == .inserted {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    Text("挿入しました")
                        .font(.caption.bold())
                    Spacer()
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    PulsingDot(
                        active: model.phase == .recording,
                        color: model.phase == .recording ? .red : .orange
                    )
                    Text(statusLabel)
                        .font(.caption.bold())
                    Spacer()
                    WaveformView(history: model.levelHistory)
                }
                Text(model.text.isEmpty ? "…" : model.text)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
        }
    }

    private var statusLabel: String {
        switch model.phase {
        case .recording: model.mode == .refined ? "録音中（AI整形）" : "録音中（素のまま）"
        case .finalizing: "確定中…"
        case .refining: "AI整形中…（Escで素のまま挿入）"
        case .inserted: "挿入しました"
        }
    }
}

struct PulsingDot: View {
    let active: Bool
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(active && pulsing ? 1.4 : 1.0)
            .opacity(active && pulsing ? 0.6 : 1.0)
            .animation(active ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                       value: pulsing)
            .onAppear { pulsing = true }
            .onChange(of: active) { _, isActive in
                pulsing = false
                if isActive { pulsing = true }
            }
    }
}

struct WaveformView: View {
    let history: [Float]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<40, id: \.self) { i in
                let index = history.count - 1 - (39 - i)
                let level = index >= 0 ? history[index] : 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green)
                    .frame(width: 3, height: CGFloat(level * 24 + 2))
            }
        }
    }
}
