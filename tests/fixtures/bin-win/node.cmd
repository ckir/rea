@echo off
if /i "%~1"=="--version" echo %STUB_node_VERSION%
if defined STUB_node_EXIT exit /b %STUB_node_EXIT%
exit /b 0
