#!/usr/bin/env bash
# Builds the Linux tarball for GitHub releases.
#   dotnet/scripts/package-linux.sh [version]
# Output: dotnet/dist/QuickProtect-<version>-linux-x64.tar.gz
#
# Counterpart of package-windows.ps1: publishes self-contained linux-x64
# (bundles .NET + the FFmpeg 7.1 natives via get-ffmpeg.sh — the csproj copies
# native/ffmpeg/linux-x64 into the app's ffmpeg/ folder at publish time).
# The tarball also carries a .desktop template and icon so manual installs and
# the AUR package (installer/aur/PKGBUILD) share one artifact.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$root/dist"
rid="linux-x64"

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
QuickProtect $version (linux-x64)

Run: ./QuickProtect/QuickProtect
Optional install: copy the QuickProtect folder to /opt/quickprotect, then
quickprotect.desktop to ~/.local/share/applications/ and quickprotect.png to
~/.local/share/icons/ (Arch users: quickprotect-bin on the AUR does this).

FFmpeg 7.1 LGPL shared libraries (BtbN builds) are bundled in QuickProtect/ffmpeg/.
Audio needs ALSA (libasound.so.2); the global hotkey needs the XDG Desktop
Portal GlobalShortcuts interface. Updates are notify-only: Settings links to
the GitHub release page.
EOF

mkdir -p "$dist"
tarball="$dist/QuickProtect-$version-$rid.tar.gz"
tar -czf "$tarball" -C "$stage/.." "$(basename "$stage")"
echo "Done: $tarball"
