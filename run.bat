@echo off
chcp 65001 >nul
cd /d "%~dp0"
wolframscript -file mclaunch.wl
if errorlevel 1 pause
