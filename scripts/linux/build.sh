#!/usr/bin/env bash
# Build the .NET app for Linux. Requires the .NET 8 SDK and system libVLC
# (e.g. sudo apt install vlc libvlc-dev).
set -euo pipefail
cd "$(dirname "$0")/../../dotnet"

command -v dotnet >/dev/null 2>&1 || {
  echo "error: dotnet not found — install the .NET 8 SDK: https://dotnet.microsoft.com/download" >&2
  exit 1
}

dotnet build QuickProtect.sln
