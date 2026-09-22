@echo off
rem ===========================================================================
rem  MiniMax H3 workstation launcher
rem
rem  KEEP THIS FILE ASCII-ONLY. Never add Chinese (or any non-ASCII) text here.
rem
rem  Why:
rem    With the active code page set to 65001 (UTF-8), cmd.exe mis-parses batch
rem    files that contain multi-byte characters. It rewinds the file by byte
rem    offset, can land in the middle of a multi-byte sequence, splits a line,
rem    and then tries to RUN the tail of that line, printing errors like:
rem        '...' is not recognized as an internal or external command
rem    All Chinese output and the real logic live in launch.ps1 instead,
rem    because PowerShell reads UTF-8 (with BOM) scripts correctly.
rem ===========================================================================

setlocal
chcp 65001 >nul
cd /d "%~dp0"

if not exist "%~dp0launch.ps1" (
  echo.
  echo  [ERROR] launch.ps1 is missing next to this file.
  echo          Please re-extract the complete folder from the release archive.
  echo.
  pause
  exit /b 1
)

rem  -NoPause: this script already pauses below when the exit code is non-zero.
rem  Without it the user would have to press Enter twice (once in launch.ps1,
rem  once here) and may think the launcher has frozen.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -NoPause
set "rc=%errorlevel%"

if not "%rc%"=="0" (
  echo.
  echo  [ERROR] The launcher exited with code %rc%.
  echo          See the message above for details.
  echo.
  pause
)

exit /b %rc%
