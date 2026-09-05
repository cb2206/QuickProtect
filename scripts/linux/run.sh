#!/usr/bin/env bash
# Build the .NET app, replace any running instance, and launch the fresh build.
set -euo pipefail
"$(dirname "$0")/build.sh"

cd "$(dirname "$0")/../../dotnet"
# Exact process name: -f would also match any process whose command line
# merely mentions the path (an editor, a tail on the log).
pkill -x QuickProtect 2>/dev/null && sleep 1 || true
exec dotnet run --project src/QuickProtect.App --no-build
