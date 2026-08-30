<#
.SYNOPSIS
    Zoom Auto Admit Windows Launcher (.NET 8)
.DESCRIPTION
    Validates .NET 8 SDK installation and executes the ZoomAutoAdmit application.
.EXAMPLE
    .\run-auto-admit.ps1
.EXAMPLE
    .\run-auto-admit.ps1 --waiting-room-auto-admit
.EXAMPLE
    .\run-auto-admit.ps1 --meeting-url "https://zoom.us/j/91473108490" --profile test1
.EXAMPLE
    .\run-auto-admit.ps1 --help
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AppArgs
)

$ErrorActionPreference = "Stop"

# 1. Verify .NET SDK is installed
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host " [ERROR] .NET SDK is not installed or not in PATH." -ForegroundColor Red
    Write-Host " Please install .NET 8.0 SDK from: https://dotnet.microsoft.com/download/dotnet/8.0" -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Red
    exit 1
}

# 2. Locate project file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    (Join-Path $scriptDir "Windows\src\ZoomAutoAdmit.Inspector\ZoomAutoAdmit.Inspector.csproj"),
    (Join-Path $scriptDir "src\ZoomAutoAdmit.Inspector\ZoomAutoAdmit.Inspector.csproj"),
    (Join-Path $scriptDir "..\Windows\src\ZoomAutoAdmit.Inspector\ZoomAutoAdmit.Inspector.csproj")
)

$projectFile = $null
foreach ($cand in $candidates) {
    if (Test-Path $cand) {
        $projectFile = (Resolve-Path $cand).Path
        break
    }
}

if (-not $projectFile) {
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host " [ERROR] Could not find ZoomAutoAdmit.Inspector.csproj" -ForegroundColor Red
    Write-Host " Checked paths:" -ForegroundColor Yellow
    $candidates | ForEach-Object { Write-Host "   - $_" -ForegroundColor DarkGray }
    Write-Host "================================================================================" -ForegroundColor Red
    exit 1
}

# 3. Default to waiting-room-auto-admit if no arguments specified
$forwardArgs = @()
if ($AppArgs -and $AppArgs.Length -gt 0) {
    $forwardArgs = $AppArgs
} else {
    $forwardArgs = @("waiting-room-auto-admit")
}

# 4. Execute application
& dotnet run --project $projectFile -- $forwardArgs
exit $LASTEXITCODE
