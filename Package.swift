// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "KoeCore", targets: ["KoeCore"]),
        .library(name: "KoeKit", targets: ["KoeKit"]),
        .library(name: "KoeDiarization", targets: ["KoeDiarization"]),
    ],
    dependencies: [
        // 話者分離（オンデバイス pyannote/CoreML）。KoeDiarization ターゲットのみが使い、
        // KoeCore / KoeKit の外部依存ゼロは維持する。
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.6"),
    ],
    targets: [
        .target(name: "KoeCore"),
        .target(name: "KoeKit", dependencies: ["KoeCore"]),
        .target(name: "KoeDiarization", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "KoeApp", dependencies: ["KoeCore", "KoeKit", "KoeDiarization"]),
        .executableTarget(name: "SpikeHotkey", path: "Spikes/SpikeHotkey"),
        .executableTarget(name: "SpikeSpeech", path: "Spikes/SpikeSpeech"),
        .executableTarget(name: "SpikePaste", path: "Spikes/SpikePaste"),
        .executableTarget(name: "SpikeSystemAudio", path: "Spikes/SpikeSystemAudio"),
        .testTarget(name: "KoeCoreTests", dependencies: ["KoeCore"]),
    ]
)
