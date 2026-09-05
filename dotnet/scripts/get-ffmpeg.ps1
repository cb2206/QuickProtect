# Downloads the FFmpeg 7.1 LGPL shared native libraries the video engine needs
# into dotnet/native/ffmpeg/<rid>/ (gitignored). Run once per checkout, or when
# bumping the FFmpeg version (must match the FFmpeg.AutoGen package major.minor).
#
#   powershell -File dotnet/scripts/get-ffmpeg.ps1 [-Rids win-x64,win-arm64]
#
# Source: https://github.com/BtbN/FFmpeg-Builds — LGPL, dynamically linked,
# redistribution-friendly with attribution (see THIRD-PARTY-NOTICES.txt).
#
# PINNED. The download is a fixed release tag with a SHA-256 per asset, not the
# rolling "latest" build: every installer and tarball must ship exactly the
# bytes that were reviewed, and a build that can't verify them fails. BtbN
# keeps its end-of-month snapshots long-term; the tag below is the last one
# that carried the n7.1 branch (their nightlies moved on to 8.x/9.x). Bumping
# FFmpeg means updating the tag, the asset names, the checksums, the
# FFmpeg.AutoGen package version, and THIRD-PARTY-NOTICES.txt together.
# Keep in sync with get-ffmpeg.sh.

param([string[]]$Rids = @("win-x64", "win-arm64"))

$ErrorActionPreference = "Stop"
$dotnetRoot = Split-Path -Parent $PSScriptRoot
$nativeRoot = Join-Path $dotnetRoot "native\ffmpeg"

$releaseTag = "autobuild-2026-07-31-14-10"
$buildId = "n7.1.5-12-g1fdbca85aa"

$assets = @{
    "win-x64"     = "ffmpeg-$buildId-win64-lgpl-shared-7.1.zip"
    "win-arm64"   = "ffmpeg-$buildId-winarm64-lgpl-shared-7.1.zip"
    "linux-x64"   = "ffmpeg-$buildId-linux64-lgpl-shared-7.1.tar.xz"
    "linux-arm64" = "ffmpeg-$buildId-linuxarm64-lgpl-shared-7.1.tar.xz"
}
$sha256 = @{
    "win-x64"     = "0f376f96fb38554ccefb1b2ae9c7c6a7b351f0e60a372b38262c320e8392c5d0"
    "win-arm64"   = "d4c07a990ae4a0b185481cba63b2ff1b621fbec39c0c5c8d9b043f5efacfd09d"
    "linux-x64"   = "f5f0ad52c6ee28a222eb10838c231469a10ad325f84063d3bc0aadf08164b3ec"
    "linux-arm64" = "28d2c354ad6cc360db0e932598f1cf5845887a1adc46415ded91baf1ca82a53b"
}

foreach ($rid in $Rids) {
    $asset = $assets[$rid]
    $expected = $sha256[$rid]
    if (-not $asset -or -not $expected) { throw "Unknown RID $rid" }
    $dest = Join-Path $nativeRoot $rid
    if ((Test-Path $dest) -and (Get-ChildItem $dest -Filter "*avcodec*" -ErrorAction SilentlyContinue)) {
        Write-Host "$rid already present, skipping"
        continue
    }
    New-Item -ItemType Directory -Force $dest | Out-Null
    $url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$releaseTag/$asset"
    $tmp = Join-Path $env:TEMP $asset
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $tmp
    $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $tmp -Force
        throw "Checksum mismatch for $asset`n  expected $expected`n  actual   $actual"
    }
    Write-Host "SHA-256 verified"
    $extract = Join-Path $env:TEMP ([IO.Path]::GetFileNameWithoutExtension($asset) + "-x")
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    if ($asset.EndsWith(".zip")) {
        Expand-Archive $tmp -DestinationPath $extract
        # The runtime DLLs live in <root>/bin
        $bin = Get-ChildItem $extract -Recurse -Directory -Filter bin | Select-Object -First 1
        Copy-Item (Join-Path $bin.FullName "*.dll") $dest
    } else {
        tar -xJf $tmp -C $extract 2>$null; if ($LASTEXITCODE -ne 0) { New-Item -ItemType Directory -Force $extract | Out-Null; tar -xJf $tmp -C $extract }
        $lib = Get-ChildItem $extract -Recurse -Directory -Filter lib | Select-Object -First 1
        Copy-Item (Join-Path $lib.FullName "*.so.*") $dest
    }
    # The build's own license file ships next to the libraries (LGPL requires it).
    $license = Get-ChildItem $extract -Recurse -Depth 1 -File -Filter "LICENSE*" | Select-Object -First 1
    if ($license) { Copy-Item $license.FullName (Join-Path $dest "LICENSE.txt") } else { Write-Warning "no LICENSE file in $asset" }
    Remove-Item $tmp -Force
    Remove-Item $extract -Recurse -Force
    Write-Host "-> $dest"
    Get-ChildItem $dest | Select-Object -ExpandProperty Name | Write-Host
}
