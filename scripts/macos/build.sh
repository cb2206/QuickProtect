#!/usr/bin/env bash
# Build the macOS app. Output: macos/build/Debug/QuickProtect.app
set -euo pipefail
cd "$(dirname "$0")/../../macos"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
}

# Sign with an Apple Development certificate when the login keychain has one.
# Ad-hoc signing (the project's Debug default, used by CI) gives every build a
# different code hash, so the Keychain treats each rebuild as a new app and
# asks for the API key/username/password again on every launch. A certificate
# makes the app's designated requirement stable, so "Always Allow" sticks.
signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "Apple Development: .*/\1/p' | head -1)"
if [ -n "$identity" ]; then
  team="$(sed -n 's/^    DEVELOPMENT_TEAM: \(.*\)$/\1/p' project.yml | head -1)"
  signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team" PROVISIONING_PROFILE_SPECIFIER=)
  echo "Signing with Apple Development identity $identity (team $team)"
else
  echo "No Apple Development identity in the keychain — ad-hoc signing (expect Keychain prompts on each launch)"
fi

xcodegen generate
xcodebuild -project QuickProtect.xcodeproj -scheme QuickProtect \
  -configuration Debug -destination 'platform=macOS' SYMROOT=build \
  "${signing[@]}" build -quiet
echo "Built: $(pwd)/build/Debug/QuickProtect.app"
