@echo off
if /i "%~1"=="--version" echo %STUB_agent_profile_VERSION%
if defined STUB_agent_profile_EXIT exit /b %STUB_agent_profile_EXIT%
exit /b 0
