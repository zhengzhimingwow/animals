@echo off
setlocal
wsl.exe --cd "%~dp0." -e bash server/run-local-playtest.sh %*
if errorlevel 1 pause
