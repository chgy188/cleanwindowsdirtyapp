@echo off
chcp 65001 >nul
setlocal

set "PS1=%~dp0src\CleanWindowsDirtyApp.ps1"

if not exist "%PS1%" (
    echo [ERROR] Script not found: %PS1%
    pause
    exit /b 1
)

rem ---- check administrator ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo  CleanWindowsDirtyApp
echo  Clean up ghost entries in Settings - Apps - Installed apps
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
pause
