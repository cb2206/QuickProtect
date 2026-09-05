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

# Integrity: the package is pinned by version AND content. Bumping $Version
# means recording the new package's SHA-256 here (Get-FileHash on the .nupkg).
$expectedSha256 = @{
    "10.0.26100.8249" = "1628c77d21ed187c4db998b37b18e267a7f092ae755589e21110c14260b14960"
}
$expected = $expectedSha256[$Version]
if (-not $expected) { throw "No SHA-256 recorded for $pkg $Version — add it to get-sdk-buildtools.ps1" }
$actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) {
    Remove-Item $tmp -Force
    throw "Checksum mismatch for $pkg $Version`n  expected $expected`n  actual   $actual"
}
Write-Host "SHA-256 verified"

# A .nupkg is a zip; we only want bin/<sdkver>/<arch>/ with the tools.
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
Expand-Archive $tmp -DestinationPath $dest
Remove-Item $tmp -Force

$makeappx = Get-ChildItem $dest -Recurse -Filter "makeappx.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe not found in $pkg $Version - package layout changed?" }

Write-Host "-> $dest"
