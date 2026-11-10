@echo off
if /i "%~1"=="--version" echo %STUB_agy_VERSION%
if defined STUB_agy_EXIT exit /b %STUB_agy_EXIT%
exit /b 0
