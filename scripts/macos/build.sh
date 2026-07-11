#!/usr/bin/env bash
# Build the macOS app. Output: macos/build/Debug/QuickProtect.app
set -euo pipefail
cd "$(dirname "$0")/../../macos"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
}

xcodegen generate
xcodebuild -project QuickProtect.xcodeproj -scheme QuickProtect \
  -configuration Debug -destination 'platform=macOS' SYMROOT=build build -quiet
echo "Built: $(pwd)/build/Debug/QuickProtect.app"
