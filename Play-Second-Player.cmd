@echo off
setlocal
wsl.exe --cd "%~dp0." -e bash server/run-local-playtest.sh second %*
if errorlevel 1 pause
