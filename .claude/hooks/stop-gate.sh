#!/usr/bin/env bash
# Stop gate (see CLAUDE.md "Loop protocol"): when a session edited code, run the
# full checks for whichever side of the repo is dirty before allowing the stop.
#   Swift edits  -> /tmp/qp-dirty-$SID      -> xcodebuild test + swiftlint --strict (from macos/)
#   C#/XAML edits -> /tmp/qp-dirty-net-$SID -> dotnet test dotnet/QuickProtect.sln
# Exit 2 blocks the stop and feeds stderr back for fixing; 5 failed attempts
# or a clean run allows the stop.
set -o pipefail

IN=$(cat)
SID=$(printf '%s' "$IN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
[ -n "$SID" ] || exit 0

SWIFT_MARK="/tmp/qp-dirty-$SID"
NET_MARK="/tmp/qp-dirty-net-$SID"
CNT="/tmp/qp-attempts-$SID"
[ -f "$SWIFT_MARK" ] || [ -f "$NET_MARK" ] || exit 0

N=$(cat "$CNT" 2>/dev/null || echo 0)
case "$N" in ''|*[!0-9]*) N=0;; esac
if [ "$N" -ge 5 ]; then
  echo "Verification still failing after 5 attempts; allowing stop. Report what remains unfixed." >&2
  rm -f "$SWIFT_MARK" "$NET_MARK" "$CNT"
  exit 0
fi

fail() { # $1 = gate name, $2 = output
  echo $((N + 1)) > "$CNT"
  printf '%s\n' "$2" >&2
  echo "[gate attempt $((N + 1))/5 failed: $1] Fix the cause, then stop again to re-verify." >&2
  exit 2
}

if [ -f "$SWIFT_MARK" ]; then
  OUT=$(cd macos && xcodebuild test -scheme QuickProtect -destination 'platform=macOS' -quiet 2>&1 | tail -40) \
    || fail "tests" "$OUT"
  SL=$(command -v swiftlint || echo /opt/homebrew/bin/swiftlint)
  if [ -x "$SL" ]; then
    OUT=$(cd macos && "$SL" lint --strict --quiet 2>&1 | tail -20) \
      || fail "swiftlint --strict" "$OUT"
  fi
fi

if [ -f "$NET_MARK" ]; then
  DOTNET=$(command -v dotnet || echo "$HOME/.dotnet/dotnet")
  if [ -x "$DOTNET" ]; then
    export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1
    OUT=$("$DOTNET" test dotnet/QuickProtect.sln 2>&1 | tail -40) \
      || fail "dotnet test" "$OUT"
  else
    echo "dotnet SDK not found; skipping the .NET gate. Note in the report that dotnet tests did not run." >&2
  fi
fi

rm -f "$SWIFT_MARK" "$NET_MARK" "$CNT"
exit 0
