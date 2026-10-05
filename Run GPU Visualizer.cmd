@echo off
setlocal
cd /d "%~dp0"
set "DOTNET_CLI_HOME=%~dp0.dotnet-home"
set "NUGET_PACKAGES=%~dp0.nuget-packages"
set "APPDATA=%~dp0.appdata"
dotnet build "%~dp0WindowsMusicVisualizerGpu\WindowsMusicVisualizerGpu.csproj" -c Release --nologo
if errorlevel 1 exit /b %errorlevel%
"%~dp0WindowsMusicVisualizerGpu\bin\Release\net10.0-windows\WindowsMusicVisualizerGpu.exe" %*
