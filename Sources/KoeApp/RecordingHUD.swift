import AppKit
import KoeCore
import SwiftUI

/// Task 16 で本実装。ここではビルドを通すための骨組み。
@MainActor
final class RecordingHUDController {
    func show(mode: RecordingMode) {}
    func updateLevel(_ level: Float) {}
    func updateText(_ text: String) {}
    func showFinalizing() {}
    func showRefining() {}
    func hide() {}
}
