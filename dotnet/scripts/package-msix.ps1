# Builds the Microsoft Store (MSIX) package.
#   powershell -File dotnet/scripts/package-msix.ps1 [-Version 1.3] [-SelfSign]
# Output: dotnet/dist/QuickProtect-<version>-win-x64.msix          (Store upload)
#         dotnet/dist/QuickProtect-<version>-win-x64-sideload.msix (-SelfSign)
#
# Notes:
#  - Publishes self-contained win-x64 (bundles .NET + the FFmpeg 7.1 natives
#    the custom video engine uses; fetched on demand by get-ffmpeg.ps1).
#  - Needs makeappx.exe (and signtool.exe when -SelfSign is used). Uses an
#    installed Windows 10/11 SDK if present — winget install
#    Microsoft.WindowsSDK.10.0.26100 — otherwise falls back to fetching just the
#    tools from NuGet via get-sdk-buildtools.ps1 (no admin, ~30 MB).
#  - Store uploads are UNSIGNED — Partner Center re-signs the package with a
#    Microsoft certificate, which is why the paid build needs no code-signing
#    certificate of its own. -SelfSign exists only so the package can be
#    sideloaded locally for testing; such a package is NOT what you upload, so
#    it is written to a separate *-sideload.msix filename to keep the two apart.
#  - IdentityName/Publisher must match Partner Center → your app → Product
#    identity exactly, or the upload is rejected (both as the publisher string
#    and via the package family name, whose suffix is a hash of it). The app is
#    reserved, so the defaults below are the real values — a plain run with no
#    -Publisher produces an uploadable package.

param(
    [string]$Version,
    [string]$IdentityName = "CBGroupLLC.QuickProtect",
    [string]$Publisher,
    [string]$PublisherDisplayName = "CB Group LLC",
    [switch]$SelfSign
)

$ErrorActionPreference = "Stop"
$desktop = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $desktop "dist"
$publish = Join-Path $dist "msix-win-x64"
$staging = Join-Path $dist "msix-staging"
$msixSource = Join-Path $desktop "installer\msix"

# Version defaults to the single source of truth so the package can't drift
# from the assembly version the updater compares against.
if (-not $Version) {
    $props = Get-Content (Join-Path $desktop "Directory.Build.props") -Raw
    if ($props -notmatch '<Version>([^<]+)</Version>') { throw "Could not read <Version> from Directory.Build.props" }
    $Version = $Matches[1]
}

# MSIX requires a four-part version; the Store reserves the revision field, so
# it must stay 0 (a non-zero revision is rejected at upload).
$parts = $Version.Split('.')
while ($parts.Count -lt 3) { $parts += "0" }
$packageVersion = "{0}.{1}.{2}.0" -f $parts[0], $parts[1], $parts[2]

# Partner Center -> QuickProtect -> Product identity. Yields package family
# name CBGroupLLC.QuickProtect_g3ygdvw278mtr; not a secret (it ships inside
# every published package), but it must match exactly or the upload is rejected.
$storePublisher = "CN=84A6E73B-CBE2-489D-A5CC-149A8CEFC7D1"
# A self-signed package must instead carry the test certificate's own subject as
# Publisher, otherwise Windows refuses to install it.
$selfSignSubject = "CN=QuickProtect Local Test"
if (-not $Publisher) {
    $Publisher = if ($SelfSign) { $selfSignSubject } else { $storePublisher }
}

& (Join-Path $PSScriptRoot "get-ffmpeg.ps1") -Rids win-x64

Write-Host "Publishing self-contained win-x64 (Release)..."
dotnet publish (Join-Path $desktop "src\QuickProtect.App") -c Release -r win-x64 --self-contained -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Write-Host "Staging package layout..."
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null
Copy-Item (Join-Path $publish "*") $staging -Recurse -Force
Copy-Item (Join-Path $msixSource "Assets") $staging -Recurse -Force

# The manifest is a template; fill in identity, publisher and version.
$manifest = Get-Content (Join-Path $msixSource "AppxManifest.xml") -Raw
$manifest = $manifest.Replace("{{IdentityName}}", $IdentityName)
$manifest = $manifest.Replace("{{Publisher}}", $Publisher)
$manifest = $manifest.Replace("{{PublisherDisplayName}}", $PublisherDisplayName)
$manifest = $manifest.Replace("{{Version}}", $packageVersion)
Set-Content -Path (Join-Path $staging "AppxManifest.xml") -Value $manifest -Encoding UTF8

# Locate makeappx.exe from the newest installed Windows SDK, falling back to the
# NuGet build-tools package so packaging works without a full SDK install.
# These are host tools, so they are probed by host architecture (x64 binaries
# still run under emulation on arm64, hence the ordered preference list).
$sdkToolArchs = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { @("arm64", "x64") }
    default { @("x64", "x86") }
}

function Find-SdkTool([string]$name) {
    $tool = Get-Command $name -ErrorAction SilentlyContinue
    if ($tool) { return $tool.Source }

    # Newest installed Windows SDK.
    $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
    $found = $roots |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Directory -ErrorAction SilentlyContinue } |
        Sort-Object Name -Descending |
        ForEach-Object { $dir = $_.FullName; $sdkToolArchs | ForEach-Object { Join-Path $dir "$_\$name" } } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if ($found) { return $found }

    # No SDK installed - fetch the tools from NuGet (cached in native/, gitignored).
    & (Join-Path $PSScriptRoot "get-sdk-buildtools.ps1")
    $toolRoot = Join-Path $desktop "native\sdk-buildtools"
    $found = Get-ChildItem $toolRoot -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $sdkToolArchs -contains (Split-Path $_.DirectoryName -Leaf) } |
        Sort-Object { $sdkToolArchs.IndexOf((Split-Path $_.DirectoryName -Leaf)) } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) { throw "$name not found. Install the Windows SDK: winget install Microsoft.WindowsSDK.10.0.26100" }
    return $found
}

$makeappx = Find-SdkTool "makeappx.exe"
# Distinct filename for sideload builds so a test package can never be mistaken
# for the uploadable one (they used to overwrite each other).
$suffix = if ($SelfSign) { "-sideload" } else { "" }
$output = Join-Path $dist "QuickProtect-$Version-win-x64$suffix.msix"
if (Test-Path $output) { Remove-Item $output -Force }

Write-Host "Packing with $makeappx..."
& $makeappx pack /d $staging /p $output /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed" }

if ($SelfSign) {
    # Local sideload testing only. Creates the certificate on first run and
    # reuses it afterwards; install it into "Trusted People" (see the README)
    # before the package will install.
    $signtool = Find-SdkTool "signtool.exe"
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $selfSignSubject } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "Creating self-signed test certificate..."
        $cert = New-SelfSignedCertificate -Type Custom -Subject $selfSignSubject `
            -KeyUsage DigitalSignature -FriendlyName "QuickProtect Local Test" `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    }
    Write-Host "Signing for local sideload..."
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $output
    if ($LASTEXITCODE -ne 0) { throw "signtool failed" }
    Write-Host "Signed with $selfSignSubject (test only - do NOT upload this to the Store)."
}

Write-Host "Done: $output"
