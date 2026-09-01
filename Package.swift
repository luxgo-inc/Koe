// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "KoeCore"),
        .executableTarget(name: "KoeApp", dependencies: ["KoeCore"]),
        .executableTarget(name: "SpikeHotkey", path: "Spikes/SpikeHotkey"),
        .executableTarget(name: "SpikeSpeech", path: "Spikes/SpikeSpeech"),
        .executableTarget(name: "SpikePaste", path: "Spikes/SpikePaste"),
        .executableTarget(name: "SpikeSystemAudio", path: "Spikes/SpikeSystemAudio"),
        .testTarget(name: "KoeCoreTests", dependencies: ["KoeCore"]),
    ]
)
