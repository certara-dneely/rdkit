@echo off
rem Build + install RDKit (run configure.bat first), then collect the Java deliverables
rem (org.RDKit.jar + GraphMolWrap.dll) in %DIST_DIR%.
call "%~dp0env.bat" || exit /b 1

cmake --build "%BUILD_DIR%" --parallel || exit /b 1
cmake --install "%BUILD_DIR%" || exit /b 1

if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
copy /Y "%RDKIT_SRC%\Code\JavaWrappers\gmwrapper\org.RDKit.jar" "%DIST_DIR%\" || exit /b 1
copy /Y "%RDKIT_SRC%\Code\JavaWrappers\gmwrapper\GraphMolWrap.dll" "%DIST_DIR%\" || exit /b 1
echo.
echo Java deliverables: %DIST_DIR%
