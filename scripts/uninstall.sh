#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: uninstall.sh [--prefix <dir>] [--purge-workspace]"
}
prefix="${HOME:?}/.local"
purge=0
while (($#)); do
    case "$1" in
        --prefix)
            [[ -n "${2:-}" && "$2" != -* ]] || { usage >&2; exit 2; }
            prefix=$2
            shift 2 ;;
        --purge-workspace) purge=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

bin="$prefix/bin"
rm -f "$bin/sonook"
for link in "$bin"/*.bundle; do
    [[ -L "$link" ]] || continue
    name=${link##*/}
    [[ "$(readlink "$link")" == "../lib/sonook/$name" ]] || continue
    rm -f "$link"
    rm -rf "$prefix/lib/sonook/$name"
done
if [[ -d "$prefix/lib/sonook" ]]; then
    rmdir "$prefix/lib/sonook" 2>/dev/null || true
fi
echo "Uninstalled $bin/sonook"
if [[ "$purge" == 1 ]]; then
    rm -rf "${HOME:?}/Sonook"
    echo "Removed $HOME/Sonook"
fi
