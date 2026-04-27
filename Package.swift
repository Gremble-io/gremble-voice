// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrembleVoice",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Core: protocols + types + text processing. Zero dependencies.
        .library(name: "GrembleVoiceCore", targets: ["GrembleVoiceCore"]),
        // Parakeet ASR adapter (FluidAudio)
        .library(name: "GrembleVoiceParakeet", targets: ["GrembleVoiceParakeet"]),
        // Whisper ASR adapter (WhisperKit)
        .library(name: "GrembleVoiceWhisper", targets: ["GrembleVoiceWhisper"]),
        // On-device LLM refinement (MLX Swift)
        .library(name: "GrembleVoiceRefinement", targets: ["GrembleVoiceRefinement"]),
        // BYOK cloud APIs (transcription + refinement)
        .library(name: "GrembleVoiceCloud", targets: ["GrembleVoiceCloud"]),
        // Mic capture + audio file playback (AVFoundation, no external deps)
        .library(name: "GrembleVoiceAudio", targets: ["GrembleVoiceAudio"]),
        // All-in-one facade: pipeline coordinator + session model. Import this in apps.
        .library(name: "GrembleVoiceEngine", targets: ["GrembleVoiceEngine"]),
    ],
    // Debug app is not a library product — run via Xcode or `swift run GrembleVoiceDebug`
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        // swift-transformers: already resolved transitively by WhisperKit; declared
        // explicitly so GrembleVoiceRefinement can use Hub + Tokenizers products directly.
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            .upToNextMinor(from: "1.1.6")),
    ],
    targets: [
        // ── Core (zero deps) ──
        .target(
            name: "GrembleVoiceCore",
            path: "Sources/Core"
        ),

        // ── Parakeet adapter ──
        .target(
            name: "GrembleVoiceParakeet",
            dependencies: [
                "GrembleVoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Parakeet"
        ),

        // ── Whisper adapter ──
        .target(
            name: "GrembleVoiceWhisper",
            dependencies: [
                "GrembleVoiceCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Whisper"
        ),

        // ── On-device LLM refinement ──
        .target(
            name: "GrembleVoiceRefinement",
            dependencies: [
                "GrembleVoiceCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // Hub + Tokenizers from swift-transformers: used by MLXRefiner's
                // Downloader and TokenizerLoader bridges.
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Refinement"
        ),

        // ── Cloud APIs (no heavy deps — just URLSession) ──
        .target(
            name: "GrembleVoiceCloud",
            dependencies: ["GrembleVoiceCore"],
            path: "Sources/Cloud"
        ),

        // ── Audio capture (AVFoundation, no external deps) ──
        .target(
            name: "GrembleVoiceAudio",
            dependencies: ["GrembleVoiceCore"],
            path: "Sources/Audio"
        ),

        // ── Engine facade (all modules + pipeline coordinator) ──
        .target(
            name: "GrembleVoiceEngine",
            dependencies: [
                "GrembleVoiceCore",
                "GrembleVoiceParakeet",
                "GrembleVoiceWhisper",
                "GrembleVoiceRefinement",
                "GrembleVoiceCloud",
                "GrembleVoiceAudio",
            ],
            path: "Sources/Engine"
        ),

        // ── Debug app — interactive pipeline testbed ──
        .executableTarget(
            name: "GrembleVoiceDebug",
            dependencies: [
                "GrembleVoiceCore",
                "GrembleVoiceAudio",
                "GrembleVoiceParakeet",
                "GrembleVoiceWhisper",
                "GrembleVoiceRefinement",
                "GrembleVoiceCloud",
            ],
            path: "Sources/DebugApp",
            exclude: ["Info.plist"]  // Xcode uses this as the app's Info.plist; SPM ignores it
        ),

        // ── Tests ──
        .testTarget(
            name: "GrembleVoiceCoreTests",
            dependencies: ["GrembleVoiceCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "GrembleVoiceParakeetTests",
            dependencies: ["GrembleVoiceParakeet"],
            path: "Tests/ParakeetTests"
        ),
        .testTarget(
            name: "GrembleVoiceCloudTests",
            dependencies: ["GrembleVoiceCloud", "GrembleVoiceCore"],
            path: "Tests/CloudTests"
        ),
        .testTarget(
            name: "GrembleVoiceRefinementTests",
            dependencies: ["GrembleVoiceRefinement"],
            path: "Tests/RefinementTests"
        ),
        .testTarget(
            name: "GrembleVoiceAudioTests",
            dependencies: ["GrembleVoiceAudio"],
            path: "Tests/AudioTests"
        ),
    ]
)
