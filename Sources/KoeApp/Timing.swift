import Foundation

/// 起動〜操作可能までの内訳を計測する開発用フック。
/// `KOE_TIMING=1` を環境変数に設定したときだけ stderr へ出す（通常運用では完全に無音）。
enum Timing {
    nonisolated(unsafe) private static let start = DispatchTime.now()
    private static let enabled = ProcessInfo.processInfo.environment["KOE_TIMING"] == "1"

    static func mark(_ label: String) {
        guard enabled else { return }
        // start は lazy static なので、先に読んで初期化を確定させる。
        // DispatchTime.now() を先に評価すると start の初期化がそれより後になり、
        // UInt64 の減算がアンダーフローしてクラッシュする。
        let origin = start.uptimeNanoseconds
        let ms = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1e6
        FileHandle.standardError.write(Data(String(format: "[timing] %8.1fms  %@\n", ms, label).utf8))
    }
}
