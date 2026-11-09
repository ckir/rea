@echo off
if /i "%~1"=="--version" echo %STUB_clavity_ls_VERSION%
if defined STUB_clavity_ls_EXIT exit /b %STUB_clavity_ls_EXIT%
exit /b 0
