# Windows build: C++ libs + Java wrapper (org.RDKit.jar / GraphMolWrap.dll) + InChI

Toolchain: Visual Studio (MSVC) + the CMake/Ninja bundled with it, SWIG >= 4.2, a JDK,
Boost and FreeType from vcpkg (static libs, dynamic CRT: triplet `x64-windows-static-md`).
No Python wrappers, no ChemDraw, no C++ tests.

    setup-deps.bat   REM clone/bootstrap vcpkg if needed, install Boost + FreeType
    configure.bat    REM cmake configure (downloads maeparser, coordgen, InChI, ... on first run)
    build.bat        REM build, install, copy jar + dll to %BUILDROOT%\java-dist

Output goes to `%BUILDROOT%` (default `C:\Projects\builds\rdkit`): `build\`, `install\`,
`java-dist\`, `vcpkg\`. Edit `env.bat` or set variables first to change tool/output paths
(`BUILDROOT`, `VSROOT`, `SWIGDIR`, `RDKIT_JDK`, `RDKIT_VCPKG`). `RDKIT_JDK` (default JDK 17) is the JDK that compiles
the jar; it overrides whatever `JAVA_HOME` is set in your environment.

`smoke\` has two tiny Java programs to verify the result:

    java -Djava.library.path=%BUILDROOT%\java-dist -cp .;%BUILDROOT%\java-dist\org.RDKit.jar Smoke

## WASM / JavaScript (MinimalLib)

    build-wasm.bat   REM RDKit's Docker build of RDKit_minimal.{js,wasm,d.ts}; output: %BUILDROOT%\wasm\build

This is a separate build (Emscripten inside a Linux container), not part of the MSVC build above.
It needs Docker Desktop running in **Linux containers** mode and Git for Windows' bash; Node is used
to run RDKit's `Code/MinimalLib/tests/tests.js` against the result (`SKIP_TESTS=1` to skip).
First run takes ~20-30 min. `build-wasm.sh` exports the **committed** source (git HEAD) with LF
line endings and runs RDKit's own `Code/MinimalLib/scripts/build_rdkitjs.sh` on that copy, so
uncommitted changes are not included, and nothing is written into your source tree. The package
version is derived from `CMakeLists.txt` the same way RDKit's CI does (e.g. `2026.9.2`).
MinimalLib has no Java API. It is built with InChI (`get_inchi`, `get_inchikey_for_inchi`).

`build-wasm.sh` also patches the *staged* `01_deps.Dockerfile` (not your repo) to add
`-DZLIB_BUILD_TESTING=OFF`: the upstream Dockerfile passes the obsolete `ZLIB_BUILD_EXAMPLES=OFF`
to zlib 1.3.2 and builds with the floating `latest` emsdk, so zlib's coverage test target
(`infcover`) fails to link. If a later RDKit release fixes the Dockerfile, the patch no-ops.

## Linux x86_64 (RHEL 9)

    build-linux.bat  REM Docker build on an AlmaLinux 9 image; output: %BUILDROOT%\linux

Same options as the Windows build (C++ libs, Java wrapper, InChI; no Python). Needs Docker Desktop in
Linux-containers mode. Built from the committed source (git HEAD) like the WASM build. AlmaLinux 9 is
binary-compatible with RHEL 9 (glibc 2.34, gcc 11). RHEL 9's Boost (1.75) and SWIG (4.1) are older than
RDKit needs (1.81 / 4.2), so the Dockerfile builds Boost (static, -fPIC) and SWIG from source. The build
fails if `libGraphMolWrap.so` needs a glibc newer than 2.34 (`MAX_GLIBC`), then runs the smoke tests on Linux.

Output: `rdkit-linux-x86_64.tar.gz` (`install/` = shared libs + headers, `java-dist/`), plus `java-dist\`
extracted. It is a tarball because the install tree has `.so` symlinks, which Windows cannot create without
elevated privileges; extract it on Linux with `tar -xzf` to keep them.

**Runtime dependency:** `libGraphMolWrap.so` links the system **freetype** (and its dependencies: libpng,
harfbuzz, brotli, graphite2, glib2, pcre, bzip2, zlib) dynamically; see `java-dist/ldd.txt`. On RHEL 9
install it with `dnf install freetype` if the host doesn't already have it.

## macOS (arm64 / x86_64)

    ./build-macos.sh   # run on a Mac; builds for the architecture of that Mac

Same options as the other platforms (C++ libs, Java wrapper, InChI; no Python). Needs Xcode command line
tools and `brew install cmake ninja swig` plus a JDK. Boost is built from source (static, deployment
target 12.0) into `$BUILDROOT/boost-<ver>-<arch>` once and reused. **FreeType is off** (macOS has no system
FreeType, and linking Homebrew's would make the library depend on `/opt/homebrew`); `FREETYPE=ON`
overrides. The script fails if `libGraphMolWrap.dylib` or an installed RDKit library depends on anything
outside `/usr/lib` and `/System`, then runs the smoke tests. There is no cross-compiling from Windows: use
a Mac or the GitHub workflows below. Output: `$BUILDROOT/java-dist` and `rdkit-macos-<arch>-install.tar.gz`.

## GitHub Actions (`.github/workflows/java_*.yml`)

| workflow | runner | what it does |
|---|---|---|
| `java_native_windows_x64.yml` | windows-2022 | `setup-deps.bat` + `configure.bat` + `build.bat` (vcpkg static Boost, cached), smoke test on JDK 21 |
| `java_native_linux_x86_64.yml` | ubuntu-latest | `build-linux.sh` (AlmaLinux 9 container for RHEL 9, SWIG+Boost layers cached, glibc 2.34 gate) |
| `java_native_macos_arm64.yml` | macos-15 | `build-macos.sh` (Boost cached) |
| `java_native_macos_x86_64.yml` | macos-15-intel | `build-macos.sh` (Boost cached) |
| `java_api.yml` | ubuntu-latest | calls the four above, diffs the public API of the four jars, smoke-tests the common jar against the Linux `.so`, uploads `rdkit-java-api`, optionally publishes to JFrog |
| `wasm_minimallib.yml` | ubuntu-24.04 | `build-wasm.sh` (Emscripten in Docker, runs the MinimalLib JS tests); artifact `rdkit-wasm`; optional `publish` input; not part of `java_api.yml` |

None runs automatically: start them from **Actions > Run workflow** (or call them with `workflow_call`).
Each native workflow uploads `rdkit-<platform>` (`java-dist/` with the jar and native library, plus the
`*-install` archive with the C++ libraries and headers).

`java_api.yml` inputs: `jar_platform` (which platform's jar is the plain Maven artifact; default
`windows-x64`, see the `int`/`long` note in `publish-jfrog.sh`), `publish` (default off) and `version`
(default: from `CMakeLists.txt`, e.g. `2026.09.2`). Publishing needs the repository secrets
`JFROG_USERNAME` and `JFROG_ACCESS_TOKEN`; the target defaults to certara-maven-develop-local and can be
changed with the repository variable `JFROG_MAVEN_URL`. It runs `publish-jfrog.sh`, so a CI publish has the
same layout as a local one (macOS classifiers are included because the workflow builds them).

`wasm_minimallib.yml` has the same `publish` / `version` inputs and secrets. It runs `publish-jfrog-wasm.sh`,
which publishes `org.rdkit:rdkit-minimallib:<version>` to the same repository: the build folder as a zip, plus
the `js`, `wasm` and `types` (`.d.ts`) files as classifiers. Locally: `build-wasm.bat`, then
`bash publish-jfrog-wasm.sh` (`DRY_RUN=1` to preview).

### Code signing (`sign` input, off by default)
`java_api.yml` and the Windows/macOS native workflows have a `sign` input (Actions > Run workflow). The Linux
library and the jars are not signed.

* **Windows** (`sign-windows.ps1`): `GraphMolWrap.dll` is Authenticode-signed by the Certara Jenkins CodeSigning
  job, the same flow as `d360-tripos-tools/.github/scripts/sign-and-fetch.ps1`: the unsigned files go to
  Artifactory staging as a tar, the Jenkins webhook starts the job, the signed tar is fetched, every signature
  is checked (`Get-AuthenticodeSignature` = Valid) and the files are copied back before the smoke test and
  packaging. The Jenkins host is not in the repository (it is public): set the repository **variables**
  `JENKINS_BASE_URL` and `JENKINS_CODESIGN_JOB` (e.g. `/job/products/job/D360/job/CodeSigning`) and the
  **secrets** `D360_CODE_SIGN_TRIGGER` (webhook token), `JFROG_ACCESS_TOKEN` (also used for publishing) and,
  recommended, `D360_JENKINS_API_USERID` + `D360_JENKINS_API_TOKEN` (without them it polls Artifactory).
* **macOS** (`sign-macos.sh`, `notarize-macos.sh`): all `.dylib`s (the JNI library and the install tree) are
  signed with the Developer ID certificate (hardened runtime + secure timestamp) inside `build-macos.sh`
  (`SIGN_IDENTITY` env), so the smoke test and the tarball see signed files; they are then notarized with
  `notarytool`. Secrets: `MACOS_CERT_P12_BASE64` (the Developer ID Application certificate + private key
  exported as .p12, base64), `MACOS_CERT_PASSWORD` (the .p12 password), `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`
  (app-specific password) and `NOTARY_TEAM_ID`. Optional variable `MACOS_SIGN_IDENTITY` (default
  `Certara USA, Inc.`). Bare dylibs cannot be stapled, Gatekeeper looks the ticket up online.

## Caveats
* **GraphMolWrap.dll only loads on JDK 21+.** It is built with MSVC 14.5x; JDK 17 bundles
  VC++ runtime 14.27 in its `bin\` and that older copy shadows the system one, so the DLL
  fails with "DLL initialization routine failed". Fixing JDK 17 needs a static-CRT rebuild
  (triplet `x64-windows-static` and a static `CMAKE_MSVC_RUNTIME_LIBRARY`).
* The jar is compiled with JDK 17, so its bytecode targets Java 17+.
* The Java wrapper writes into the source tree (`Code/JavaWrappers/gmwrapper`: generated
  `.java`, `org.RDKit.jar`, and the installed `GraphMolWrap.dll`). All are git-ignored except
  `GraphMolWrap.dll`, which is excluded locally via `.git/info/exclude`.
