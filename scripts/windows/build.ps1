# Build the .NET app for Windows. Requires the .NET 10 SDK (projects target net8.0).
$ErrorActionPreference = "Stop"
$repo = Split-Path (Split-Path $PSScriptRoot)

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "dotnet not found - install the .NET 10 SDK: https://dotnet.microsoft.com/download"
}

dotnet build (Join-Path $repo "dotnet\QuickProtect.sln")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
