@echo off
if /i "%~1"=="--version" echo %STUB_wt_VERSION%
if defined STUB_wt_EXIT exit /b %STUB_wt_EXIT%
exit /b 0
