// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Sonook",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "WorkflowKit", targets: ["WorkflowKit"]),
        .library(name: "ContentKit", targets: ["ContentKit"]),
        .library(name: "NarrativeKit", targets: ["NarrativeKit"]),
        .library(name: "DirectorKit", targets: ["DirectorKit"]),
        .library(name: "SpeechKit", targets: ["SpeechKit"]),
        .library(name: "AudioRenderKit", targets: ["AudioRenderKit"]),
        .library(name: "KnowledgeKit", targets: ["KnowledgeKit"]),
        .library(name: "DistributionKit", targets: ["DistributionKit"]),
        .library(name: "EngineServer", targets: ["EngineServer"]),
        .library(name: "ModelRuntime", targets: ["ModelRuntime"]),
        .library(name: "EngineSDK", targets: ["EngineSDK"]),
        .executable(name: "sonook", targets: ["SonookCLI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            .upToNextMinor(from: "0.33.0")
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "6759555f2bd8f18c242102d73d149efde9f2f2e0",
            traits: []
        ),
        .package(
            url: "https://github.com/Neywa-Labs/mlx-audio-swift.git",
            revision: "c7755e2504181a771941bb6f9f26ea79b3cdfce3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            .upToNextMajor(from: "1.4.0")
        )
    ],
    targets: [
        .target(name: "AudioCore"),
        .target(name: "StorageKit", dependencies: ["AudioCore"]),
        .target(name: "WorkflowKit", dependencies: ["AudioCore"]),
        .target(name: "ContentKit", dependencies: ["AudioCore"]),
        .target(name: "NarrativeKit", dependencies: ["AudioCore"]),
        .target(name: "DirectorKit", dependencies: ["AudioCore"]),
        .target(name: "SpeechKit", dependencies: ["AudioCore"]),
        .target(name: "AudioRenderKit", dependencies: ["AudioCore"]),
        .target(name: "KnowledgeKit", dependencies: ["AudioCore", "StorageKit"]),
        .target(name: "DistributionKit", dependencies: ["AudioCore", "AudioRenderKit"]),
        .target(name: "EngineServer", dependencies: ["AudioCore", "StorageKit", "KnowledgeKit", "DistributionKit"]),
        .target(
            name: "ModelRuntime",
            dependencies: [
                "AudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift")
            ]
        ),
        .target(
            name: "EngineSDK",
            dependencies: [
                "AudioCore",
                "StorageKit",
                "WorkflowKit",
                "ContentKit",
                "NarrativeKit",
                "DirectorKit",
                "SpeechKit",
                "AudioRenderKit",
                "KnowledgeKit",
                "DistributionKit",
                "EngineServer",
                "ModelRuntime"
            ]
        ),
        .executableTarget(
            name: "SonookCLI",
            dependencies: [
                "AudioCore",
                "StorageKit",
                "WorkflowKit",
                "ContentKit",
                "NarrativeKit",
                "DirectorKit",
                "SpeechKit",
                "AudioRenderKit",
                "KnowledgeKit",
                "DistributionKit",
                "EngineServer",
                "ModelRuntime",
                "EngineSDK"
            ]
        ),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: ["AudioCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "StorageKitTests", dependencies: ["AudioCore", "StorageKit"]),
        .testTarget(name: "EngineSDKTests", dependencies: ["EngineSDK", "AudioCore", "AudioRenderKit"]),
        .testTarget(name: "WorkflowKitTests", dependencies: ["AudioCore", "StorageKit", "WorkflowKit"]),
        .testTarget(name: "ContentKitTests", dependencies: ["AudioCore", "ContentKit"]),
        .testTarget(name: "NarrativeKitTests", dependencies: ["AudioCore", "NarrativeKit", "DirectorKit"]),
        .testTarget(name: "DirectorKitTests", dependencies: ["AudioCore", "DirectorKit"]),
        .testTarget(name: "SpeechKitTests", dependencies: ["AudioCore", "StorageKit", "SpeechKit", "AudioRenderKit"]),
        .testTarget(name: "AudioRenderKitTests", dependencies: ["AudioCore", "AudioRenderKit"]),
        .testTarget(name: "KnowledgeKitTests", dependencies: ["AudioCore", "StorageKit", "KnowledgeKit"]),
        .testTarget(name: "DistributionKitTests", dependencies: ["AudioCore", "AudioRenderKit", "StorageKit", "DistributionKit"]),
        .testTarget(name: "EngineServerTests", dependencies: ["AudioCore", "StorageKit", "AudioRenderKit", "KnowledgeKit", "DistributionKit", "EngineServer"])
    ]
)
