@echo off
setlocal

where dotnet >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo ================================================================================
    echo  [ERROR] .NET SDK is not installed or not found in PATH.
    echo  Please install .NET 8.0 SDK from: https://dotnet.microsoft.com/download/dotnet/8.0
    echo ================================================================================
    exit /b 1
)

set SCRIPT_DIR=%~dp0
set CSPROJ=%SCRIPT_DIR%Windows\src\ZoomAutoAdmit.Inspector\ZoomAutoAdmit.Inspector.csproj

if not exist "%CSPROJ%" (
    set CSPROJ=%SCRIPT_DIR%src\ZoomAutoAdmit.Inspector\ZoomAutoAdmit.Inspector.csproj
)

if not exist "%CSPROJ%" (
    echo [ERROR] Could not find ZoomAutoAdmit.Inspector.csproj
    exit /b 1
)

if "%~1"=="" (
    dotnet run --project "%CSPROJ%" -- waiting-room-auto-admit
) else (
    dotnet run --project "%CSPROJ%" -- %*
)
