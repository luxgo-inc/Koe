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
        model.text = ""
        if panel == nil { panel = makePanel() }
        positionAtBottom()
        panel?.orderFrontRegardless()
    }

    func updateLevel(_ level: Float) { model.level = level }
    func updateText(_ text: String) { model.text = text }
    func showFinalizing() { model.phase = .finalizing }
    func showRefining() { model.phase = .refining }
    func hide() { panel?.orderOut(nil) }

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
    enum Phase { case recording, finalizing, refining }
    var mode: RecordingMode = .raw
    var phase: Phase = .recording
    var level: Float = 0
    var text = ""
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.phase == .recording ? Color.red : Color.orange)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.caption.bold())
                Spacer()
                LevelMeter(level: model.level)
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

    private var statusLabel: String {
        switch model.phase {
        case .recording: model.mode == .refined ? "録音中（AI整形）" : "録音中（素のまま）"
        case .finalizing: "確定中…"
        case .refining: "AI整形中…（Escで素のまま挿入）"
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) / 10 < level ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 3, height: 12)
            }
        }
    }
}
