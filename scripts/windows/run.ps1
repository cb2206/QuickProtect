# Build the .NET app, replace any running instance, and launch the fresh build.
$ErrorActionPreference = "Stop"
$repo = Split-Path (Split-Path $PSScriptRoot)

& (Join-Path $PSScriptRoot "build.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# The assembly is QuickProtect.dll, so the process name is "QuickProtect".
# Killing it (not just signaling) matters: the single-instance guard makes a
# second launch defer to the running instance and exit.
Get-Process "QuickProtect" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

dotnet run --project (Join-Path $repo "dotnet\src\QuickProtect.App") --no-build
