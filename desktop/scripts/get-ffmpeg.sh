#!/usr/bin/env bash
# Downloads the FFmpeg 7.1 LGPL shared native libraries the video engine needs
# into desktop/native/ffmpeg/<rid>/ (gitignored). Run once per checkout, or when
# bumping the FFmpeg version (must match the FFmpeg.AutoGen package major.minor).
#
#   desktop/scripts/get-ffmpeg.sh [rid...]        # default: host-arch Linux RID
#
# Sources: https://github.com/BtbN/FFmpeg-Builds (nightly "latest" of the n7.1
# branch, LGPL, dynamically linked — redistribution-friendly with attribution).
# Counterpart of get-ffmpeg.ps1, which defaults to the Windows RIDs.

set -euo pipefail

desktop="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_root="$desktop/native/ffmpeg"

asset_for() {
    case "$1" in
        linux-x64)   echo "ffmpeg-n7.1-latest-linux64-lgpl-shared-7.1.tar.xz" ;;
        linux-arm64) echo "ffmpeg-n7.1-latest-linuxarm64-lgpl-shared-7.1.tar.xz" ;;
        win-x64)     echo "ffmpeg-n7.1-latest-win64-lgpl-shared-7.1.zip" ;;
        win-arm64)   echo "ffmpeg-n7.1-latest-winarm64-lgpl-shared-7.1.zip" ;;
        *)           echo "" ;;
    esac
}

host_rid() {
    case "$(uname -m)" in
        aarch64|arm64) echo "linux-arm64" ;;
        x86_64)        echo "linux-x64" ;;
        *)             echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
    esac
}

rids=("$@")
[ ${#rids[@]} -eq 0 ] && rids=("$(host_rid)")

for rid in "${rids[@]}"; do
    asset="$(asset_for "$rid")"
    if [ -z "$asset" ]; then
        echo "Unknown RID $rid" >&2
        exit 1
    fi
    dest="$native_root/$rid"
    if compgen -G "$dest/*avcodec*" > /dev/null; then
        echo "$rid already present, skipping"
        continue
    fi
    mkdir -p "$dest"
    url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$asset"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading $url"
    curl -fsSL -o "$tmp/$asset" "$url"
    mkdir -p "$tmp/x"
    case "$asset" in
        *.zip)
            unzip -q "$tmp/$asset" -d "$tmp/x"
            # The runtime DLLs live in <root>/bin
            find "$tmp/x" -type d -name bin -exec sh -c 'cp "$1"/*.dll "$2"' _ {} "$dest" \;
            ;;
        *)
            tar -xJf "$tmp/$asset" -C "$tmp/x"
            find "$tmp/x" -type d -name lib -exec sh -c 'cp -P "$1"/*.so.* "$2"' _ {} "$dest" \;
            ;;
    esac
    rm -rf "$tmp"
    trap - EXIT
    echo "-> $dest"
    ls "$dest"
done
