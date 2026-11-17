@echo off
rem Configure RDKit: C++ libs + Java (SWIG) wrapper + InChI. No Python wrappers.
rem Run setup-deps.bat first. Build output goes to %BUILDROOT% (default C:\Projects\builds\rdkit).
call "%~dp0env.bat" || exit /b 1

rem -U drops any cached Java/JNI locations so a changed RDKIT_JDK is actually picked up.
cmake -S "%RDKIT_SRC%" -B "%BUILD_DIR%" -G Ninja ^
  -UJava_* -UJAVA_* -UJNI_* ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_TOOLCHAIN_FILE="%RDKIT_VCPKG%\scripts\buildsystems\vcpkg.cmake" ^
  -DVCPKG_TARGET_TRIPLET=%VCPKG_TRIPLET% ^
  -DBoost_USE_STATIC_LIBS=ON ^
  -DRDK_BUILD_PYTHON_WRAPPERS=OFF ^
  -DRDK_BUILD_SWIG_WRAPPERS=ON ^
  -DRDK_BUILD_SWIG_JAVA_WRAPPER=ON ^
  -DSWIG_EXECUTABLE="%SWIGDIR%\swig.exe" ^
  -DSWIG_DIR="%SWIGDIR%\Lib" ^
  -DRDK_BUILD_INCHI_SUPPORT=ON ^
  -DRDK_BUILD_CHEMDRAW_SUPPORT=OFF ^
  -DRDK_BUILD_CPP_TESTS=OFF ^
  -DRDK_INSTALL_INTREE=OFF ^
  -DCMAKE_INSTALL_PREFIX="%INSTALL_DIR%"
