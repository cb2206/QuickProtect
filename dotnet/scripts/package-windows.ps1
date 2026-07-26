# Builds the free (unsigned) Windows installer for GitHub releases.
#   powershell -File dotnet/scripts/package-windows.ps1 [-Version 1.3]
# Output: dotnet/dist/QuickProtect-Setup-<version>-win-x64.exe
#
# The paid Microsoft Store build is a different artifact — see package-msix.ps1.
#
# Notes:
#  - Publishes self-contained win-x64 (bundles .NET + the FFmpeg 7.1 natives
#    the custom video engine uses; fetched on demand by get-ffmpeg.ps1).
#  - Requires Inno Setup 6 (winget install JRSoftware.InnoSetup).

param([string]$Version)

$ErrorActionPreference = "Stop"
$desktop = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $desktop "dist"
$publish = Join-Path $dist "win-x64"

# Version defaults to the single source of truth so the installer can't drift
# from the assembly version the updater compares against (same as package-msix.ps1).
if (-not $Version) {
    $props = Get-Content (Join-Path $desktop "Directory.Build.props") -Raw
    if ($props -notmatch '<Version>([^<]+)</Version>') { throw "Could not read <Version> from Directory.Build.props" }
    $Version = $Matches[1]
}

& (Join-Path $PSScriptRoot "get-ffmpeg.ps1") -Rids win-x64

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

Write-Host "Done: $dist\QuickProtect-Setup-$Version-win-x64.exe"
