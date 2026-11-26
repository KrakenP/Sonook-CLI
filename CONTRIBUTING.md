# Contributing to Sonook

Start with the [architecture](ARCHITECTURE.md) and the [roadmap](ROADMAP.md) to find the module responsible for your change. Use the original story in [Tests/AudioCoreTests/Fixtures](Tests/AudioCoreTests/Fixtures) for examples and reproducible reports.

## Build and test

Use an Apple Silicon Mac, macOS 14+, a full Xcode with Swift 6.3+ and the Metal Toolchain. Run from the repository root. The initial build needs access to the pinned SwiftPM repositories.

```sh
xcodebuild -downloadComponent MetalToolchain
swift build -c release
.build/release/sonook help
./scripts/check.sh
```

The default check enforces module boundaries and builds the non-GPU test targets. Run `./scripts/check.sh --full` for the full Swift package build and test suite, including the MLX/Metal targets. On a fresh checkout, use the full check if the fast path has no built test runner. For a single suite use, for example, `swift test --filter PlaybackSyncEngineTests`. Local model weights are needed for real inference runs. The deterministic unit, fault-injection and fixture integration suites run without them.

Run the Python 3 integration suites against the release executable just built:

```sh
python3 Tests/Integration/universal_audio_cli.py .build/release/sonook
python3 Tests/Integration/p5_server_sync_client.py .build/release/sonook
python3 Tests/Integration/p6_install_smoke.py .build/release/sonook
```

The first exercises production and export with fixture audio. The second publishes and verifies packs and starts a real loopback HTTP/SSE client and server. The 1.0 installer smoke suite stages its own temporary home and prefix and verifies the version, doctor and both uninstall modes. All three suites isolate their work in temporary directories. macOS must permit the system audio encoder and loopback sockets. To exercise real models, follow the [local setup and production walkthrough](README.md) in a separate workspace with authorized inputs. Report the machine, model revision, quantization and units alongside any performance number.

## Preserve the engine contracts

- Keep UI frameworks out of the engine. AudioCore defines portable domain types and provider contracts. Put concrete MLX integrations in ModelRuntime. Keep storage, networking and model implementation dependencies out of AudioCore. Implement business logic in shared application services so CLI and SDK use the same behavior.
- A provider declares its capabilities. Reject unsupported parameters or record the degradation explicitly. Validate model output, and preserve failure and manual-review states. A failed local provider must never silently switch to a cloud service.
- Persist long-running jobs, honor cancellation at a safe checkpoint and preserve verified assets on resume and local regeneration. Keep origin, script, character, model revision and checksums traceable. Source offsets are half-open UTF-8 byte ranges in the normalized text.
- Version public data and interfaces. Exercise migrations against existing data. Respect the loopback default, scoped authentication, private-workspace boundary and the public pack allowlist. [Security](SECURITY.md) · [Pack specification](docs/specs/audiopack-v1.md)
- Add tests for new behavior and regressions. Exercise provider contracts with fakes, and cover interruption, retries, migration or partial writes where the change affects those paths. Never commit private text, voice references, credentials, model weights or machine-specific paths.

## Decisions and pull requests

For a significant architecture or public-contract change, add the next numbered decision under [docs/adr](docs/adr). Describe the context, decision, alternatives, consequences and evidence. Distinguish measurements from proposals. Update the architecture, wire specification and both READMEs wherever a public behavior changes.

A pull request should explain what the caller can now do, which interfaces or stored formats changed, and which checks ran. Include sanitized reproduction steps or a small original fixture. For dependencies or models, update the lockfile where applicable and record the upstream license and redistribution terms in the [third-party audit](docs/THIRD_PARTY_LICENSES.md). Use the [private reporting process](SECURITY.md) for vulnerabilities. Contributions intended for inclusion are subject to the [Apache-2.0 license](LICENSE).
