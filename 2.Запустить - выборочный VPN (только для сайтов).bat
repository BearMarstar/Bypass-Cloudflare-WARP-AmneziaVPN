@echo off
cd /d "%~dp0"

set SCRIPT=%~dp0utils\config_split.ps1

if not exist "%SCRIPT%" (
    echo [ERROR] НЕ НАЙДЕН:
    echo %SCRIPT%
    pause
    exit
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

pause