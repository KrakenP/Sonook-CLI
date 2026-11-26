#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: install.sh [--prefix <dir>] [--skip-build] [--init-workspace]"
}
prefix="${HOME:?}/.local"
skip_build=0
init_workspace=0
while (($#)); do
    case "$1" in
        --prefix)
            [[ -n "${2:-}" && "$2" != -* ]] || { usage >&2; exit 2; }
            prefix=$2
            shift 2 ;;
        --skip-build) skip_build=1; shift ;;
        --init-workspace) init_workspace=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
release="$root/.build/release"
if [[ "$skip_build" == 0 || ! -f "$release/sonook" ]]; then
    (cd "$root" && swift build -c release)
fi

mkdir -p "$prefix/bin"
bin=$(cd "$prefix/bin" && pwd)
if [[ -d "$bin/sonook" ]]; then
    echo "Install destination is a directory: $bin/sonook" >&2
    exit 1
fi
staged=$(mktemp "$bin/.sonook.XXXXXX")
trap 'rm -f "$staged"' EXIT
cp "$release/sonook" "$staged"
chmod 755 "$staged"

# SwiftPM and MLX look up runtime bundles next to the executable. Keep their contents
# under this prefix and leave other applications' bundles alone on install and uninstall.
for bundle in "$release"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    name=${bundle##*/}
    [[ "$name" != *Tests.bundle ]] || continue
    target="../lib/sonook/$name"
    if [[ -e "$bin/$name" || -L "$bin/$name" ]]; then
        if [[ ! -L "$bin/$name" || "$(readlink "$bin/$name")" != "$target" ]]; then
            echo "A different installation owns $bin/$name. Choose a separate --prefix." >&2
            exit 1
        fi
    fi
    mkdir -p "$prefix/lib/sonook"
    ditto "$bundle" "$prefix/lib/sonook/$name"
    [[ -L "$bin/$name" ]] || ln -s "$target" "$bin/$name"
done
mv -f "$staged" "$bin/sonook"
echo "Installed $bin/sonook"
case ":${PATH:-}:" in
    *":$bin:"*) ;;
    *) printf 'Add this line to ~/.zshrc:\nexport PATH=%q:"$PATH"\n' "$bin" ;;
esac

if [[ "$init_workspace" == 1 ]]; then
    "$bin/sonook" doctor
    cat <<'EXAMPLES'
Register your local model directories before building an audiobook:
  sonook model register --id qwen-llm --kind llm --provider mlx-swift-lm --path /path/to/llm
  sonook model register --id audition --kind tts --provider qwen3-tts-voice-design --path /path/to/voice-design
  sonook model register --id narrator --kind tts --provider voxcpm2-mlx --path /path/to/voxcpm2
  sonook model register --id transcriber --kind asr --provider qwen3-asr-mlx --path /path/to/asr
EXAMPLES
fi
