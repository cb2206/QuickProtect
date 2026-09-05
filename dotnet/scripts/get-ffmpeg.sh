#!/usr/bin/env bash
# Downloads the FFmpeg 7.1 LGPL shared native libraries the video engine needs
# into dotnet/native/ffmpeg/<rid>/ (gitignored). Run once per checkout, or when
# bumping the FFmpeg version (must match the FFmpeg.AutoGen package major.minor).
#
#   dotnet/scripts/get-ffmpeg.sh [rid...]        # default: host-arch Linux RID
#
# Source: https://github.com/BtbN/FFmpeg-Builds — LGPL, dynamically linked,
# redistribution-friendly with attribution (see THIRD-PARTY-NOTICES.txt).
#
# PINNED. The download is a fixed release tag with a SHA-256 per asset, not the
# rolling "latest" build: every installer and tarball must ship exactly the
# bytes that were reviewed, and a build that can't verify them fails. BtbN
# keeps its end-of-month snapshots long-term; the tag below is the last one
# that carried the n7.1 branch (their nightlies moved on to 8.x/9.x). Bumping
# FFmpeg means updating the tag, the asset names, the checksums, the
# FFmpeg.AutoGen package version, and THIRD-PARTY-NOTICES.txt together.
# Counterpart of get-ffmpeg.ps1, which defaults to the Windows RIDs.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_root="$root/native/ffmpeg"

release_tag="autobuild-2026-07-31-14-10"
build_id="n7.1.5-12-g1fdbca85aa"

asset_for() {
    case "$1" in
        linux-x64)   echo "ffmpeg-$build_id-linux64-lgpl-shared-7.1.tar.xz" ;;
        linux-arm64) echo "ffmpeg-$build_id-linuxarm64-lgpl-shared-7.1.tar.xz" ;;
        win-x64)     echo "ffmpeg-$build_id-win64-lgpl-shared-7.1.zip" ;;
        win-arm64)   echo "ffmpeg-$build_id-winarm64-lgpl-shared-7.1.zip" ;;
        *)           echo "" ;;
    esac
}

sha256_for() {
    case "$1" in
        linux-x64)   echo "f5f0ad52c6ee28a222eb10838c231469a10ad325f84063d3bc0aadf08164b3ec" ;;
        linux-arm64) echo "28d2c354ad6cc360db0e932598f1cf5845887a1adc46415ded91baf1ca82a53b" ;;
        win-x64)     echo "0f376f96fb38554ccefb1b2ae9c7c6a7b351f0e60a372b38262c320e8392c5d0" ;;
        win-arm64)   echo "d4c07a990ae4a0b185481cba63b2ff1b621fbec39c0c5c8d9b043f5efacfd09d" ;;
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

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

rids=("$@")
[ ${#rids[@]} -eq 0 ] && rids=("$(host_rid)")

for rid in "${rids[@]}"; do
    asset="$(asset_for "$rid")"
    expected="$(sha256_for "$rid")"
    if [ -z "$asset" ] || [ -z "$expected" ]; then
        echo "Unknown RID $rid" >&2
        exit 1
    fi
    dest="$native_root/$rid"
    if compgen -G "$dest/*avcodec*" > /dev/null; then
        echo "$rid already present, skipping"
        continue
    fi
    mkdir -p "$dest"
    url="https://github.com/BtbN/FFmpeg-Builds/releases/download/$release_tag/$asset"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading $url"
    curl -fsSL -o "$tmp/$asset" "$url"
    actual="$(sha256_file "$tmp/$asset")"
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $asset" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        exit 1
    fi
    echo "SHA-256 verified"
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
    # The build's own license file ships next to the libraries (LGPL requires it).
    license="$(find "$tmp/x" -maxdepth 2 -iname 'LICENSE*' | head -1 || true)"
    if [ -n "$license" ]; then cp "$license" "$dest/LICENSE.txt"; else echo "warning: no LICENSE file in $asset" >&2; fi
    rm -rf "$tmp"
    trap - EXIT
    echo "-> $dest"
    ls "$dest"
done
