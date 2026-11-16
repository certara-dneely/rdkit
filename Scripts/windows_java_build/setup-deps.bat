@echo off
rem Install the third-party dependencies RDKit needs, via vcpkg:
rem   Boost 1.81+ (static libs, dynamic CRT) and FreeType.
rem Clones and bootstraps vcpkg into %RDKIT_VCPKG% if it is not there yet. Safe to re-run.
call "%~dp0env.bat" || exit /b 1

if not exist "%RDKIT_VCPKG%\vcpkg.exe" (
  if not exist "%RDKIT_VCPKG%\bootstrap-vcpkg.bat" (
    git clone --depth 1 https://github.com/microsoft/vcpkg.git "%RDKIT_VCPKG%" || exit /b 1
  )
  call "%RDKIT_VCPKG%\bootstrap-vcpkg.bat" -disableMetrics || exit /b 1
)

rem vcpkg classic mode must run from the vcpkg root
pushd "%RDKIT_VCPKG%"
"%RDKIT_VCPKG%\vcpkg.exe" install --triplet %VCPKG_TRIPLET% --disable-metrics ^
  boost-cmake boost-serialization boost-iostreams boost-system ^
  boost-algorithm boost-dynamic-bitset boost-property-tree boost-flyweight boost-lexical-cast ^
  boost-tokenizer boost-format boost-random boost-graph boost-numeric-conversion boost-range ^
  boost-json boost-property-map boost-multiprecision boost-filesystem boost-unordered ^
  boost-rational boost-math boost-multi-array boost-crc boost-assign boost-any boost-multi-index ^
  boost-smart-ptr boost-preprocessor boost-locale boost-program-options boost-variant2 ^
  boost-container boost-predef boost-parameter boost-integer boost-optional boost-function ^
  boost-tuple boost-utility boost-functional boost-core boost-config boost-log ^
  freetype
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
