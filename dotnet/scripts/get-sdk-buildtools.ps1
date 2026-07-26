# Downloads the Windows SDK packaging tools (makeappx.exe, signtool.exe) into
# dotnet/native/sdk-buildtools/ (gitignored). Used as a fallback by
# package-msix.ps1 when no full Windows SDK is installed.
#
#   powershell -File dotnet/scripts/get-sdk-buildtools.ps1 [-Version 10.0.26100.8249]
#
# Source: the Microsoft.Windows.SDK.BuildTools NuGet package (~30 MB), which
# ships the same signed tools as the full SDK but needs no admin rights and no
# 3 GB install. Pinned so packaging is reproducible; the default tracks the
# 26100 (Windows 11 24H2) SDK generation the README's winget command installs.

param([string]$Version = "10.0.26100.8249")

$ErrorActionPreference = "Stop"
$desktop = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $desktop "native\sdk-buildtools\$Version"

if (Test-Path (Join-Path $dest "bin")) {
    Write-Host "SDK build tools $Version already present, skipping"
    return
}

$pkg = "microsoft.windows.sdk.buildtools"
$url = "https://api.nuget.org/v3-flatcontainer/$pkg/$Version/$pkg.$Version.nupkg"
$tmp = Join-Path $env:TEMP "$pkg.$Version.zip"

Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $tmp

# A .nupkg is a zip; we only want bin/<sdkver>/<arch>/ with the tools.
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
Expand-Archive $tmp -DestinationPath $dest
Remove-Item $tmp -Force

$makeappx = Get-ChildItem $dest -Recurse -Filter "makeappx.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe not found in $pkg $Version - package layout changed?" }

Write-Host "-> $dest"
