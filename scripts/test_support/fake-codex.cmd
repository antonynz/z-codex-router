@echo off
rem Deterministic local Codex stub for executable documentation tests.
echo %* | findstr /c:"--help" >nul && exit /b 0
if "%1 %2 %3"=="plugin marketplace list" echo {"marketplaces":[]}
exit /b 0
