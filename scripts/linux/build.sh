#!/usr/bin/env bash
# Build the .NET app for Linux. Requires the .NET 8 SDK. For video, fetch the
# FFmpeg 9.0 natives once per checkout: dotnet/scripts/get-ffmpeg.sh
# (falls back to system FFmpeg 7.x, else the app runs without video).
set -euo pipefail
cd "$(dirname "$0")/../../dotnet"

command -v dotnet >/dev/null 2>&1 || {
  echo "error: dotnet not found — install the .NET 8 SDK: https://dotnet.microsoft.com/download" >&2
  exit 1
}

dotnet build QuickProtect.sln
