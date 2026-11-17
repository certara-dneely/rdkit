@echo off
rem Shared environment for the Windows (MSVC + Ninja + vcpkg) RDKit Java-wrapper build.
rem Every path can be overridden by setting the variable before calling these scripts.

for %%I in ("%~dp0..\..") do set "RDKIT_SRC=%%~fI"

if not defined BUILDROOT set "BUILDROOT=C:\Projects\builds\rdkit"
set "BUILD_DIR=%BUILDROOT%\build"
set "INSTALL_DIR=%BUILDROOT%\install"
set "DIST_DIR=%BUILDROOT%\java-dist"
if not defined RDKIT_VCPKG set "RDKIT_VCPKG=%BUILDROOT%\vcpkg"
if not defined VCPKG_TRIPLET set "VCPKG_TRIPLET=x64-windows-static-md"
rem make sure vcpkg uses OUR clone even if the environment (e.g. a CI runner) points VCPKG_ROOT elsewhere
set "VCPKG_ROOT=%RDKIT_VCPKG%"

if not defined VSROOT set "VSROOT=C:\Program Files\Microsoft Visual Studio\18\Professional"
set "VSCMAKE=%VSROOT%\Common7\IDE\CommonExtensions\Microsoft\CMake"

rem SWIG >= 4.2 (winget install SWIG.SWIG)
if not defined SWIGDIR set "SWIGDIR=%LOCALAPPDATA%\Microsoft\WinGet\Packages\SWIG.SWIG_Microsoft.Winget.Source_8wekyb3d8bbwe\swigwin-4.5.1"

rem JDK used to compile org.RDKit.jar. 17 keeps the bytecode usable on Java 17+.
rem NOTE: the resulting GraphMolWrap.dll only LOADS on JDK 21+ (JDK 17 bundles an older VC++ runtime).
rem This deliberately overrides any JAVA_HOME already in the environment; set RDKIT_JDK to change it.
if not defined RDKIT_JDK set "RDKIT_JDK=C:\Tools\jdk-17.0.2+8"
set "JAVA_HOME=%RDKIT_JDK%"

call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
set "PATH=%JAVA_HOME%\bin;%PATH%"
rem Use the CMake/Ninja bundled with Visual Studio and the SWIG folder when present; otherwise (e.g. on a
rem GitHub runner, where VSROOT points at VS 2022) fall back to whatever is already on PATH.
if exist "%VSCMAKE%\CMake\bin\cmake.exe" set "PATH=%VSCMAKE%\CMake\bin;%VSCMAKE%\Ninja;%PATH%"
if exist "%SWIGDIR%\swig.exe" set "PATH=%SWIGDIR%;%PATH%"
