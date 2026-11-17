#!/usr/bin/env bash
# Build the macOS RDKit C++ libraries + Java wrapper (libGraphMolWrap.dylib, org.RDKit.jar) + InChI,
# natively on a Mac (arm64 or x86_64: the architecture of the machine running this script).
# Same options as the Windows/Linux builds: no Python wrappers, no ChemDraw, no C++ tests.
#
# Requirements: Xcode command line tools, cmake, ninja, SWIG >= 4.2 (brew install cmake ninja swig),
# a JDK (JAVA_HOME, or `java_home` finds one), curl.
# Boost is built from source (static, PIC, deployment-target-clean) into $BOOST_PREFIX, once, and reused.
# FreeType is turned off: macOS has no system FreeType, so linking Homebrew's would make the library
# depend on /opt/homebrew (or /usr/local). Set FREETYPE=ON to enable it anyway.
#
# Output (under $BUILDROOT, default ~/rdkit-build):
#   java-dist/org.RDKit.jar, java-dist/libGraphMolWrap.dylib (+ otool.txt)
#   rdkit-macos-<arch>-install.tar.gz   (install/ = shared libs + headers)
# The build fails if a produced library depends on anything outside /usr/lib and /System (portability
# gate, like the glibc check on Linux).
#
# Optional env: BUILDROOT, BOOST_VERSION (1.92.0), BOOST_PREFIX, DEPLOYMENT_TARGET (12.0), JOBS,
#               FREETYPE (OFF), SKIP_SMOKE=1,
#               SIGN_IDENTITY (+ KEYCHAIN): code-sign the libraries (see sign-macos.sh, notarize-macos.sh)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: macOS only." >&2; exit 1; }
ARCH="$(uname -m)"                              # arm64 | x86_64
BUILDROOT="${BUILDROOT:-$HOME/rdkit-build}"
BOOST_VERSION="${BOOST_VERSION:-1.92.0}"
BOOST_PREFIX="${BOOST_PREFIX:-$BUILDROOT/boost-$BOOST_VERSION-$ARCH}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-12.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
FREETYPE="${FREETYPE:-OFF}"
BUILD_DIR="$BUILDROOT/build-$ARCH"
INSTALL_DIR="$BUILDROOT/install"
DIST_DIR="$BUILDROOT/java-dist"
TARBALL="$BUILDROOT/rdkit-macos-$ARCH-install.tar.gz"
mkdir -p "$BUILDROOT"

die() { echo "ERROR: $*" >&2; exit 1; }
for t in cmake ninja swig curl; do command -v "$t" >/dev/null 2>&1 || die "$t not found (brew install cmake ninja swig)."; done
swig -version | sed -n 's/^SWIG Version \([0-9.]*\).*/SWIG \1/p'
if [ -z "${JAVA_HOME:-}" ]; then JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null)" || die "no JDK found; set JAVA_HOME."; fi
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
echo "arch=$ARCH  deployment target=$DEPLOYMENT_TARGET  jobs=$JOBS  JAVA_HOME=$JAVA_HOME"

# --- Boost (static, PIC; only the compiled libraries RDKit links) --------------------------------
if [ ! -f "$BOOST_PREFIX/lib/libboost_serialization.a" ]; then
  echo "Building Boost $BOOST_VERSION into $BOOST_PREFIX"
  BOOST_US="${BOOST_VERSION//./_}"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/boost.tar.bz2" "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_US}.tar.bz2"
  tar -xjf "$TMP/boost.tar.bz2" -C "$TMP"
  ( cd "$TMP/boost_${BOOST_US}" \
    && ./bootstrap.sh --with-toolset=clang --prefix="$BOOST_PREFIX" \
         --with-libraries=serialization,iostreams,system,filesystem >/dev/null \
    && ./b2 -j"$JOBS" link=static variant=release threading=multi \
         -sNO_LZMA=1 -sNO_ZSTD=1 \
         cxxflags="-fPIC -arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
         cflags="-fPIC -arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
         linkflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
         install >/dev/null )
  rm -rf "$TMP"
else
  echo "Using cached Boost in $BOOST_PREFIX"
fi

# --- configure / build / install ----------------------------------------------------------------
# The Java wrapper writes into the source tree (Code/JavaWrappers/gmwrapper), like on the other platforms.
cmake -S "$REPO" -B "$BUILD_DIR" -G Ninja \
  "-UJava_*" "-UJAVA_*" "-UJNI_*" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_PREFIX_PATH="$BOOST_PREFIX" \
  -DBoost_USE_STATIC_LIBS=ON \
  -DRDK_BUILD_PYTHON_WRAPPERS=OFF \
  -DRDK_BUILD_SWIG_WRAPPERS=ON \
  -DRDK_BUILD_SWIG_JAVA_WRAPPER=ON \
  -DRDK_BUILD_INCHI_SUPPORT=ON \
  -DRDK_BUILD_CHEMDRAW_SUPPORT=OFF \
  -DRDK_BUILD_FREETYPE_SUPPORT="$FREETYPE" \
  -DRDK_BUILD_CPP_TESTS=OFF \
  -DRDK_INSTALL_INTREE=OFF \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
cmake --build "$BUILD_DIR" --parallel "$JOBS"
rm -rf "$INSTALL_DIR"; cmake --install "$BUILD_DIR"

# --- collect the Java deliverables -----------------------------------------------------------------
GM="$REPO/Code/JavaWrappers/gmwrapper"
rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"
cp "$GM/org.RDKit.jar" "$DIST_DIR/"
# CMake names the JNI module .dylib or .jnilib depending on version; both load via System.loadLibrary
# on JDK 7+. Normalise to .dylib.
NATIVE="$(ls "$GM"/libGraphMolWrap.dylib "$GM"/libGraphMolWrap.jnilib "$GM"/libGraphMolWrap.so 2>/dev/null | head -1)" \
  || true
[ -n "$NATIVE" ] || die "no libGraphMolWrap.* found in $GM"
cp "$NATIVE" "$DIST_DIR/libGraphMolWrap.dylib"

# --- optional code signing (before the gate, smoke test and tarball, so all of them see the signed files) ---------
# Needs SIGN_IDENTITY (and KEYCHAIN if the identity is not in the default search list). Notarization is a
# separate, later step (notarize-macos.sh): it does not change the files.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "Signing libraries as '$SIGN_IDENTITY'"
  bash "$HERE/sign-macos.sh" "$DIST_DIR" "$INSTALL_DIR/lib"
fi

# --- portability gate: only system libraries (or RDKit's own, via @rpath) allowed ------------------------------------------------
check_deps() {
  local f="$1" bad
  bad="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/|@rpath/libRDKit|@loader_path/)' || true)"
  # a dylib's own install name is listed too: ignore that line
  bad="$(echo "$bad" | grep -v -F "$(basename "$f")" || true)"
  if [ -n "$bad" ]; then echo "ERROR: $f depends on non-system libraries:" >&2; echo "$bad" >&2; return 1; fi
}
{ echo "== libGraphMolWrap.dylib"; otool -L "$DIST_DIR/libGraphMolWrap.dylib"
  echo "== min macOS: $(otool -l "$DIST_DIR/libGraphMolWrap.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  echo "== arch: $(lipo -archs "$DIST_DIR/libGraphMolWrap.dylib")"; } | tee "$DIST_DIR/otool.txt"
check_deps "$DIST_DIR/libGraphMolWrap.dylib"
for f in "$INSTALL_DIR"/lib/*.dylib; do [ -f "$f" ] && [ ! -L "$f" ] && check_deps "$f" || true; done

# --- smoke tests (arch-native, so they really load the library) --------------------------------------
if [ "${SKIP_SMOKE:-0}" != "1" ]; then
  OUT="$(mktemp -d)"
  javac -d "$OUT" -cp "$DIST_DIR/org.RDKit.jar" "$HERE"/smoke/*.java
  for t in Smoke InchiSmoke; do java -Djava.library.path="$DIST_DIR" -cp "$OUT:$DIST_DIR/org.RDKit.jar" "$t"; done
  rm -rf "$OUT"
fi

# --- package the install tree (shared libs have symlinks: keep them in a tarball) -------------------
tar -czf "$TARBALL" -C "$BUILDROOT" install
echo
echo "macOS ($ARCH) build complete:"
echo "  Java deliverables : $DIST_DIR"
echo "  C++ libs+headers  : $TARBALL"
