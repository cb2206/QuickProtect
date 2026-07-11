# Build the .NET app, replace any running instance, and launch the fresh build.
$ErrorActionPreference = "Stop"
$repo = Split-Path (Split-Path $PSScriptRoot)

& (Join-Path $PSScriptRoot "build.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Get-Process "QuickProtect.App" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

dotnet run --project (Join-Path $repo "dotnet\src\QuickProtect.App") --no-build
