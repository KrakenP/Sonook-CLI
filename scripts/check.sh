#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_FULL=0
for arg in "$@"; do
    if [[ "$arg" == "--full" ]]; then
        BUILD_FULL=1
    fi
done
if [[ "${SONOOK_BUILD_ALL:-0}" == "1" ]]; then
    BUILD_FULL=1
fi

echo "[1/3] Checking architecture redlines..."
# Redline 1: Core engine targets must never import UI frameworks (SwiftUI, AppKit, UIKit, CarPlay)
if grep -rnE '^\s*import\s+(SwiftUI|AppKit|UIKit|CarPlay)\b' Sources 2>/dev/null; then
    echo "ERROR: Architecture Redline #1 violated — core engine targets must not import UI frameworks." >&2
    exit 1
fi

# Redline 1 & 2: AudioCore must not depend on concrete model frameworks, storage, or networking
if grep -rnE '^\s*import\s+(MLX|MLXLLM|MLXVLM|MLXLMCommon|MLXAudioCore|MLXAudioTTS|MLXAudioSTT|GRDB|SQLite3|Vapor|NIO|Network)\b' Sources/AudioCore 2>/dev/null; then
    echo "ERROR: Architecture Redline #1/#2 violated — AudioCore must remain framework- and provider-agnostic." >&2
    exit 1
fi

# Redline 1 & 2: Only ModelRuntime may link MLX; all domain/pipeline kits must remain model-framework agnostic
if grep -rnE '^\s*import\s+(MLX|MLXLLM|MLXVLM|MLXLMCommon|MLXAudioCore|MLXAudioTTS|MLXAudioSTT)\b' \
    Sources/StorageKit Sources/WorkflowKit Sources/ContentKit Sources/NarrativeKit Sources/DirectorKit Sources/SpeechKit Sources/AudioRenderKit Sources/KnowledgeKit Sources/DistributionKit Sources/EngineServer 2>/dev/null; then
    echo "ERROR: Architecture Redline #1/#2 violated — only ModelRuntime may import MLX frameworks." >&2
    exit 1
fi

# Privacy guard: disallow hardcoded user home paths or local credentials in tracked sources and tests.
if grep -rnE '/Users/[^/]+/|/home/[^/]+/|C:\\Users\\' Sources Tests 2>/dev/null; then
    echo "ERROR: Privacy guard violated — do not hardcode user home directory paths in Sources/ or Tests/." >&2
    exit 1
fi

mkdir -p "$ROOT_DIR/.build/clang-module-cache" "$ROOT_DIR/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export TMPDIR="$ROOT_DIR/.build/tmp"

SWIFT_PM_FLAGS=()
if [[ "${SONOOK_DISABLE_SWIFTPM_SANDBOX:-auto}" == "1" ]]; then
    SWIFT_PM_FLAGS+=(--disable-sandbox)
elif [[ "${SONOOK_DISABLE_SWIFTPM_SANDBOX:-auto}" == "auto" ]]; then
    if ! swift package dump-package >/dev/null 2>&1; then
        SWIFT_PM_FLAGS+=(--disable-sandbox)
    fi
fi

if [[ "$BUILD_FULL" == "1" ]]; then
    echo "[2/3] Building full Swift package (including ModelRuntime & MLX Metal shaders)..."
    swift build ${SWIFT_PM_FLAGS[@]+"${SWIFT_PM_FLAGS[@]}"}
    echo "[3/3] Running full Swift test suite..."
    swift test ${SWIFT_PM_FLAGS[@]+"${SWIFT_PM_FLAGS[@]}"}
else
    echo "[2/3] Building all 11 non-GPU engine & kit test targets..."
    for target in AudioCoreTests StorageKitTests WorkflowKitTests ContentKitTests NarrativeKitTests DirectorKitTests SpeechKitTests AudioRenderKitTests KnowledgeKitTests DistributionKitTests EngineServerTests; do
        swift build --target "$target" ${SWIFT_PM_FLAGS[@]+"${SWIFT_PM_FLAGS[@]}"}
    done
    echo "[3/3] Running unit & contract test suites..."
    swift test --skip-build ${SWIFT_PM_FLAGS[@]+"${SWIFT_PM_FLAGS[@]}"}
fi

echo "ALL CHECKS PASSED."
