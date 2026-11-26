# Third-party software, model and audio licenses

Sonook (听澜) source is released under [Apache-2.0](../LICENSE). This inventory covers the Apple Silicon release build, system components it uses and the assets an operator can bring to a production. The source distribution includes no model weights, recorded sound library or voice samples.

## Swift Package Manager

The four direct dependencies (mlx-swift, mlx-swift-lm, mlx-audio-swift and swift-transformers) come from [Package.swift](../Package.swift). The table includes **all 14** direct and transitive pins in [Package.resolved](../Package.resolved). Repository URLs reproduce the lockfile. Each license link points at the exact resolved commit, including for tagged versions.

| Package and locked repository URL | Version or revision | Upstream license | Attribution or role |
|---|---|---|---|
| **eventsource** · `https://github.com/mattt/EventSource.git` | `1.6.0` | [MIT](https://github.com/mattt/EventSource/blob/bb4b61273b5a976bb571859c17f903ebc3439df1/LICENSE.md) | Mattt (2025), SSE client library |
| **mlx-audio-swift** · `https://github.com/Neywa-Labs/mlx-audio-swift.git` | `c7755e2504181a771941bb6f9f26ea79b3cdfce3` | [MIT](https://github.com/Neywa-Labs/mlx-audio-swift/blob/c7755e2504181a771941bb6f9f26ea79b3cdfce3/LICENSE) | Prince Canuma (2025), speech inference |
| **mlx-swift** · `https://github.com/ml-explore/mlx-swift.git` | `0.33.0` | [MIT](https://github.com/ml-explore/mlx-swift/blob/7ede4fd6d05f63305c1c0ebf4f8c1909a637c574/LICENSE) | ml-explore (2023), MLX arrays and Metal kernels |
| **mlx-swift-lm** · `https://github.com/ml-explore/mlx-swift-lm.git` | `6759555f2bd8f18c242102d73d149efde9f2f2e0` | [MIT](https://github.com/ml-explore/mlx-swift-lm/blob/6759555f2bd8f18c242102d73d149efde9f2f2e0/LICENSE) | ml-explore (2024), language-model inference |
| **swift-asn1** · `https://github.com/apple/swift-asn1.git` | `1.7.5` | [Apache-2.0](https://github.com/apple/swift-asn1/blob/97fd57437fc94cfa6b62f2b8f84c50f433534e17/LICENSE.txt) | ASN.1 types |
| **swift-collections** · `https://github.com/apple/swift-collections.git` | `1.7.6` | [Apache-2.0 with Swift Runtime Library Exception](https://github.com/apple/swift-collections/blob/88754449ab766a739610b660e117762115fabc9c/LICENSE.txt) | Collection types |
| **swift-crypto** · `https://github.com/apple/swift-crypto.git` | `4.5.2` | [Apache-2.0](https://github.com/apple/swift-crypto/blob/da9d28d69ebe3894b18376c8f2395c2f37b8448f/LICENSE.txt) | Cryptographic primitives |
| **swift-huggingface** · `https://github.com/huggingface/swift-huggingface.git` | `1.0.1` | [Apache-2.0](https://github.com/huggingface/swift-huggingface/blob/84ced3d4fa31b1bc8c74f420d346f690cb6b0f35/LICENSE) | Hub client support |
| **swift-jinja** · `https://github.com/huggingface/swift-jinja.git` | `3.2.1` | [Apache-2.0](https://github.com/huggingface/swift-jinja/blob/3104efda56131c37dda52e9142f02cc2425c02e6/LICENSE) | Chat templates |
| **swift-numerics** · `https://github.com/apple/swift-numerics` | `1.1.1` | [Apache-2.0 with Swift Runtime Library Exception](https://github.com/apple/swift-numerics/blob/0c0290ff6b24942dadb83a929ffaaa1481df04a2/LICENSE.txt) | Numeric types |
| **swift-syntax** · `https://github.com/swiftlang/swift-syntax.git` | `603.0.2` | [Apache-2.0 with Swift Runtime Library Exception](https://github.com/swiftlang/swift-syntax/blob/79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1/LICENSE.txt) | Syntax and macro tooling |
| **swift-transformers** · `https://github.com/huggingface/swift-transformers.git` | `1.4.0` | [Apache-2.0](https://github.com/huggingface/swift-transformers/blob/402a8a1105f52038b0949d9596981fc9e32bed17/LICENSE) | Local tokenizers |
| **yyjson** · `https://github.com/ibireme/yyjson.git` | `0.13.0` | [MIT](https://github.com/ibireme/yyjson/blob/6447536015f3d600f3d65323b10976103b337ca7/LICENSE) | YaoYuan (2020), JSON parsing |
| **zstd** · `https://github.com/facebook/zstd.git` | `1.6.0` | [BSD-3-Clause or GPLv2](https://github.com/facebook/zstd/blob/916e8e70b33317d469a41ee837e47317807815c8/LICENSE) | Meta Platforms and affiliates, Zstandard compression |

The macOS lockfile has no `swift-argument-parser` pin. MLX Swift declares it for its Linux CUDA build tool under `#if os(Linux)`. Sonook parses its CLI arguments in its own executable. [Pinned upstream manifest](https://github.com/ml-explore/mlx-swift/blob/7ede4fd6d05f63305c1c0ebf4f8c1909a637c574/Package.swift)

For source or binary redistribution, carry forward the license text and required copyright, attribution and NOTICE entries for the components actually shipped. Preserve the Swift Runtime Library Exception text on the three packages that include it. For zstd the BSD terms are available independently of the GPLv2 alternative. [Alternative zstd license](https://github.com/facebook/zstd/blob/916e8e70b33317d469a41ee837e47317807815c8/COPYING)

Swift ASN.1 credits SwiftNIO and Swift OpenAPI Generator. Swift Crypto credits SwiftNIO and Wycheproof test vectors and includes component-specific notices. Preserve those that apply to the redistributed files. [Swift ASN.1 NOTICE](https://github.com/apple/swift-asn1/blob/97fd57437fc94cfa6b62f2b8f84c50f433534e17/NOTICE.txt) · [Swift Crypto NOTICE](https://github.com/apple/swift-crypto/blob/da9d28d69ebe3894b18376c8f2395c2f37b8448f/NOTICE.txt)

MLX Swift also incorporates native sources below `Source/Cmlx`. These do not appear as separate SwiftPM pins. Among them are MLX and MLX C (MIT), nlohmann/json (MIT), fmt (MIT with an optional exception) and Apple metal-cpp (Apache-2.0). Preserve the license files in the corresponding vendored directories when redistributing them. [Native sources at the locked revision](https://github.com/ml-explore/mlx-swift/tree/7ede4fd6d05f63305c1c0ebf4f8c1909a637c574/Source/Cmlx) · [Vendoring record](https://github.com/ml-explore/mlx-swift/blob/7ede4fd6d05f63305c1c0ebf4f8c1909a637c574/Source/Cmlx/vendor-README.md)

## System libraries and frameworks

| Component | Supplied by | Terms and use |
|---|---|---|
| SQLite3 | macOS system library | Public-domain SQLite, used for the workspace, transactional jobs, search and sync history. [SQLite copyright dedication](https://sqlite.org/copyright.html) |
| Foundation, CryptoKit, AVFoundation | Apple SDK and OS | Files and serialization, SHA-256 and cryptographic keys, audio encoding, decoding and rendering. Apple SDK terms apply. [Apple agreements](https://developer.apple.com/support/terms/) |
| Network, Security, Accelerate, Compression, CoreMedia, CoreFoundation, Darwin and Metal | Apple SDK, OS and toolchain | Local service and TLS, signal processing, archive decoding, media timing, system calls and GPU execution. Users install Apple's tools separately. [Apple agreements](https://developer.apple.com/support/terms/) |

## User-downloaded model weights

Register a compatible local MLX weight directory for each stage. The publishers below identify the original checkpoint and license. Check the provenance, revision and license of the specific conversion or quantization you download. Model registration records the operator-supplied license.

| Recommended checkpoint | Role in Sonook | Publisher's license |
|---|---|---|
| Qwen3.5-9B | Chapter analysis, character profiles and speaker attribution. The measured configuration used 4-bit weights. | [Apache-2.0 · Qwen model card](https://huggingface.co/Qwen/Qwen3.5-9B) |
| Qwen3-TTS-12Hz-1.7B-VoiceDesign | Generate short reference voices locally from character descriptions. | [Apache-2.0 · Qwen model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign) |
| VoxCPM2 | Synthesize 48 kHz speech with a consistent reference voice. The benchmark used 8-bit weights. | [Apache-2.0 · OpenBMB model card](https://huggingface.co/openbmb/VoxCPM2) |
| Qwen3-ASR-1.7B | Local transcription and read-back quality checks. | [Apache-2.0 · Qwen model card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) |

Historical comparisons include additional checkpoints and research-only models. Their individual terms apply if obtained separately. Sonook grants rights to its own code. Text, adaptations, speaker likeness, reference recordings and the resulting production each require appropriate rights. [P0 comparison](../Benchmarks/p0-baseline.md)

## Ambient recordings, foley and optional generated effects

- Automatic selection uses a local library of ambient and foley field recordings labeled CC0-1.0 or public domain. Record the creator/source, dedication or public-domain basis, attribution and file hash for each asset in the library manifest. The scanner assumes a curated directory. A scan cannot establish ownership or grant rights. [CC0 dedication](https://creativecommons.org/publicdomain/zero/1.0/) · [Library registry](../Sources/AudioRenderKit/SoundLibraryRegistry.swift)
- An operator may explicitly configure a local executable through `SubprocessSFXProvider`. The helper and its model are obtained separately and are never bundled in Sonook core. The bridge passes a local request, validates the returned audio and records the model revision and license in the cached asset. The operator is responsible for the executable and its permissions. [Provider bridge](../Sources/AudioRenderKit/SFXProviderBridge.swift)
- **Stable Audio Open Small** is an example of a possible external helper backend. Its weights use the Stability AI Community License, with separate eligibility and commercial conditions. Installing Sonook neither installs this model nor grants rights under those terms. [Publisher's model card](https://huggingface.co/stabilityai/stable-audio-open-small) · [Stability AI license](https://stability.ai/license)
