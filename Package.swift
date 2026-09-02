// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "KoeCore", targets: ["KoeCore"]),
        .library(name: "KoeKit", targets: ["KoeKit"]),
    ],
    targets: [
        .target(name: "KoeCore"),
        .target(name: "KoeKit", dependencies: ["KoeCore"]),
        .executableTarget(name: "KoeApp", dependencies: ["KoeCore", "KoeKit"]),
        .executableTarget(name: "SpikeHotkey", path: "Spikes/SpikeHotkey"),
        .executableTarget(name: "SpikeSpeech", path: "Spikes/SpikeSpeech"),
        .executableTarget(name: "SpikePaste", path: "Spikes/SpikePaste"),
        .executableTarget(name: "SpikeSystemAudio", path: "Spikes/SpikeSystemAudio"),
        .testTarget(name: "KoeCoreTests", dependencies: ["KoeCore"]),
    ]
)
