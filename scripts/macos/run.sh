#!/usr/bin/env bash
# Build the macOS app, replace any running instance, and launch the fresh build.
set -euo pipefail
"$(dirname "$0")/build.sh"

APP="$(cd "$(dirname "$0")/../../macos" && pwd)/build/Debug/QuickProtect.app"
pkill -x QuickProtect 2>/dev/null && sleep 1 || true
open "$APP"
echo "Launched: $APP"
