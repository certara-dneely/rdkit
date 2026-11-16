@echo off
rem Build the RDKit WASM/JS module (MinimalLib) via RDKit's Docker recipe. See build-wasm.sh.
rem Needs Docker Desktop running (Linux containers). Output: %BUILDROOT%\wasm\build
if not defined BUILDROOT set "BUILDROOT=C:\Projects\builds\rdkit"

rem Find Git for Windows' bash (NOT the WSL bash.exe in System32).
set "GITBASH="
for /f "delims=" %%G in ('where git') do (
  if not defined GITBASH if exist "%%~dpG..\bin\bash.exe" for %%H in ("%%~dpG..\bin\bash.exe") do set "GITBASH=%%~fH"
  if not defined GITBASH if exist "%%~dpG..\..\bin\bash.exe" for %%H in ("%%~dpG..\..\bin\bash.exe") do set "GITBASH=%%~fH"
)
if not defined GITBASH (
  echo ERROR: could not locate Git for Windows' bash.exe from git on PATH.
  exit /b 1
)

"%GITBASH%" "%~dp0build-wasm.sh" %*
exit /b %ERRORLEVEL%
