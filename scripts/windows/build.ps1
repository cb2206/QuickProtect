# Build the .NET app for Windows. Requires the .NET 8 SDK.
$ErrorActionPreference = "Stop"
$repo = Split-Path (Split-Path $PSScriptRoot)

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "dotnet not found - install the .NET 8 SDK: https://dotnet.microsoft.com/download"
}

dotnet build (Join-Path $repo "dotnet\QuickProtect.sln")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
