@echo off
if /i "%~1"=="--version" echo %STUB_npx_VERSION%
if defined STUB_npx_EXIT exit /b %STUB_npx_EXIT%
exit /b 0
