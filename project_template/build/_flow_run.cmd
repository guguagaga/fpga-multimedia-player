@echo off
setlocal
set "RD=%~1"
set "TD_FLOW_SCRIPT=%~2"
set "TD_CMD=%~3"
if not defined TD_CMD if defined CODEC9_TD_CMD set "TD_CMD=%CODEC9_TD_CMD%"
if not defined TD_CMD (
  if exist "D:\bin\td_commands_prompt.exe" (
    set "TD_CMD=D:\bin\td_commands_prompt.exe"
  ) else (
    set "TD_CMD=D:\TD3\bin\td_commands_prompt.exe"
  )
)
if not exist "%TD_CMD%" (
  echo Tang Dynasty executable not found: "%TD_CMD%"
  echo Supply the full executable path as argument 3.
  exit /b 2
)
cd /d "%RD%"
if errorlevel 1 exit /b 2
copy /y "%~dp0run_flow.tcl" ".td_flow_driver.tcl" >nul
if errorlevel 1 exit /b 2
"%TD_CMD%" ".td_flow_driver.tcl" > "flow_stdout.txt" 2>&1
set "FLOW_RC=%ERRORLEVEL%"
echo FLOW_EXIT=%FLOW_RC% >> "flow_stdout.txt"
exit /b %FLOW_RC%
