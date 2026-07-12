# Downloads the FFmpeg 7.1 LGPL shared native libraries the video engine needs
# into dotnet/native/ffmpeg/<rid>/ (gitignored). Run once per checkout, or when
# bumping the FFmpeg version (must match the FFmpeg.AutoGen package major.minor).
#
#   powershell -File dotnet/scripts/get-ffmpeg.ps1 [-Rids win-x64,win-arm64]
#
# Sources: https://github.com/BtbN/FFmpeg-Builds (nightly "latest" of the n7.1
# branch, LGPL, dynamically linked — redistribution-friendly with attribution).

param([string[]]$Rids = @("win-x64", "win-arm64"))

$ErrorActionPreference = "Stop"
$desktop = Split-Path -Parent $PSScriptRoot
$nativeRoot = Join-Path $desktop "native\ffmpeg"

$assets = @{
    "win-x64"     = "ffmpeg-n7.1-latest-win64-lgpl-shared-7.1.zip"
    "win-arm64"   = "ffmpeg-n7.1-latest-winarm64-lgpl-shared-7.1.zip"
    "linux-x64"   = "ffmpeg-n7.1-latest-linux64-lgpl-shared-7.1.tar.xz"
    "linux-arm64" = "ffmpeg-n7.1-latest-linuxarm64-lgpl-shared-7.1.tar.xz"
}

foreach ($rid in $Rids) {
    $asset = $assets[$rid]
    if (-not $asset) { throw "Unknown RID $rid" }
    $dest = Join-Path $nativeRoot $rid
    if ((Test-Path $dest) -and (Get-ChildItem $dest -Filter "*avcodec*" -ErrorAction SilentlyContinue)) {
        Write-Host "$rid already present, skipping"
        continue
    }
    New-Item -ItemType Directory -Force $dest | Out-Null
    $url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$asset"
    $tmp = Join-Path $env:TEMP $asset
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $tmp
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
    Remove-Item $tmp -Force
    Remove-Item $extract -Recurse -Force
    Write-Host "-> $dest"
    Get-ChildItem $dest | Select-Object -ExpandProperty Name | Write-Host
}
