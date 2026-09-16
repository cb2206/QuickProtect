#!/usr/bin/env bash
# Builds a Linux tarball for GitHub releases.
#   dotnet/scripts/package-linux.sh [--rid linux-x64|linux-arm64] [version]
# Output: dotnet/dist/QuickProtect-<version>-<rid>.tar.gz
#
# Counterpart of package-windows.ps1: publishes self-contained for one RID
# (bundles .NET + the FFmpeg 9.0 natives via get-ffmpeg.sh — the csproj copies
# native/ffmpeg/<rid> into the app's ffmpeg/ folder at publish time).
# The tarball also carries a .desktop template and icon so manual installs and
# the AUR package (installer/aur/PKGBUILD) share one artifact.
#
# arm64 cross-publishes fine from an x64 runner: the publish is plain
# self-contained (no ReadyToRun/AOT), so nothing is compiled for the target
# architecture — the RID only selects which prebuilt natives get copied.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$root/dist"

rid="linux-x64"
if [ "${1:-}" = "--rid" ]; then
    [ -n "${2:-}" ] || { echo "--rid needs a value (linux-x64 or linux-arm64)" >&2; exit 1; }
    rid="$2"
    shift 2
fi
case "$rid" in
    linux-x64|linux-arm64) ;;
    *) echo "unsupported rid '$rid' (expected linux-x64 or linux-arm64)" >&2; exit 1 ;;
esac

# Version defaults to the single source of truth so the tarball can't drift
# from the assembly version the updater compares against (same as the Windows
# packaging scripts).
version="${1:-}"
if [ -z "$version" ]; then
    version="$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$root/Directory.Build.props")"
    [ -n "$version" ] || { echo "Could not read <Version> from Directory.Build.props" >&2; exit 1; }
fi

"$root/scripts/get-ffmpeg.sh" "$rid"

echo "Publishing self-contained $rid (Release)..."
stage="$dist/QuickProtect-$version-$rid"
rm -rf "$stage"
dotnet publish "$root/src/QuickProtect.App" -c Release -r "$rid" --self-contained -o "$stage/QuickProtect"

# Desktop entry template + icon (Exec path assumes /opt; adjust for manual installs).
cat > "$stage/quickprotect.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=QuickProtect
Comment=Live viewer for UniFi Protect cameras
Exec=/opt/quickprotect/QuickProtect
Icon=quickprotect
Categories=Utility;AudioVideo;
Terminal=false
EOF
cp "$root/installer/msix/Assets/Square310x310Logo.png" "$stage/quickprotect.png"

cat > "$stage/README" <<EOF
QuickProtect $version ($rid)

Run: ./QuickProtect/QuickProtect
Optional install: copy the QuickProtect folder to /opt/quickprotect, then
quickprotect.desktop to ~/.local/share/applications/ and quickprotect.png to
~/.local/share/icons/ (Arch users: quickprotect-bin on the AUR does this).

FFmpeg 9.0 LGPL shared libraries (BtbN builds) are bundled in QuickProtect/ffmpeg/;
their license and the other third-party notices are in QuickProtect/THIRD-PARTY-NOTICES.txt.
Audio needs ALSA (libasound.so.2); the global hotkey needs the XDG Desktop
Portal GlobalShortcuts interface. Updates are notify-only: Settings links to
the GitHub release page.
EOF

mkdir -p "$dist"
tarball="$dist/QuickProtect-$version-$rid.tar.gz"
tar -czf "$tarball" -C "$stage/.." "$(basename "$stage")"
echo "Done: $tarball"
