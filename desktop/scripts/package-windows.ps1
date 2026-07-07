# Builds the distributable Windows installer.
#   powershell -File desktop/scripts/package-windows.ps1 [-Version 1.2.1]
# Output: desktop/dist/QuickProtect-Setup-<version>-x64.exe
#
# Notes:
#  - Publishes self-contained win-x64 (bundles .NET + libVLC). There is no
#    arm64 libVLC NuGet, so x64 is the only Windows target with video; it runs
#    under emulation on Windows-on-ARM.
#  - Requires Inno Setup 6 (winget install JRSoftware.InnoSetup).

param([string]$Version = "1.2.1")

$ErrorActionPreference = "Stop"
$desktop = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $desktop "dist"
$publish = Join-Path $dist "win-x64"

Write-Host "Publishing self-contained win-x64 (Release)..."
dotnet publish (Join-Path $desktop "src\QuickProtect.App") -c Release -r win-x64 --self-contained -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if (-not $iscc) {
    $candidates = @(
        "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { throw "Inno Setup not found. Install with: winget install JRSoftware.InnoSetup" }
    $iscc = $found
} else {
    $iscc = $iscc.Source
}

Write-Host "Compiling installer with $iscc..."
& $iscc (Join-Path $desktop "installer\QuickProtect.iss") /DAppVersion=$Version /DPublishDir=$publish /DOutputDir=$dist
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }

Write-Host "Done: $dist\QuickProtect-Setup-$Version-x64.exe"
