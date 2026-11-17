#!/usr/bin/env bash
# Build RDKit MinimalLib (RDKit_minimal.js / .wasm / .d.ts) using RDKit's own Docker recipe
# (Code/MinimalLib/scripts/build_rdkitjs.sh), but from a clean, LF-normalised export of the
# COMMITTED source (git HEAD) instead of the working tree. This avoids:
#   * CRLF line endings (core.autocrlf=true) breaking the shell script / Dockerfiles in Linux,
#   * the Windows build's downloaded externals and generated files being copied into the image,
#   * Code/MinimalLib/build being created inside your source tree.
# Uncommitted changes are therefore NOT included. Output: $BUILDROOT/wasm/build
#
# Requirements: Docker Desktop running in Linux-containers mode (with `docker compose`), Git Bash,
# and Node.js (only for the test step; set SKIP_TESTS=1 to skip it).
# Optional env: BUILDROOT, NPM_VERSION, SKIP_TESTS=1, KEEP_STAGE=1
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

BUILDROOT="${BUILDROOT:-C:/Projects/builds/rdkit}"
if command -v cygpath >/dev/null 2>&1; then BUILDROOT="$(cygpath -u "$BUILDROOT")"; fi
WASM_ROOT="$BUILDROOT/wasm"
STAGE="$WASM_ROOT/src"
OUT="$WASM_ROOT/build"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
docker info >/dev/null 2>&1 || die "Docker engine not reachable. Start Docker Desktop and re-run."
[ "$(docker info --format '{{.OSType}}' 2>/dev/null)" = "linux" ] \
  || die "Docker is in Windows-containers mode. Switch Docker Desktop to Linux containers."
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) is required."

if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  echo "NOTE: uncommitted changes to tracked files exist; they are NOT included (building HEAD)."
fi

# --- stage a clean LF copy of HEAD -----------------------------------------------------------
echo "Staging committed source to $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"
git -C "$REPO" -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD | tar -x -C "$STAGE"

# --- workaround for upstream Dockerfile (applied to the staged copy only) --------------------
# 01_deps.Dockerfile builds zlib 1.3.2 with the floating "latest" emsdk and passes
# -DZLIB_BUILD_EXAMPLES=OFF, an option zlib 1.3.2 no longer has (it is ZLIB_BUILD_TESTING, default ON).
# zlib's coverage-instrumented test target (infcover) then fails to link with current emcc
# (undefined llvm_gcda_*). We only need the library, so turn the tests off.
DEPS_DOCKERFILE="$STAGE/Code/MinimalLib/docker/01_deps.Dockerfile"
if grep -q -- '-DZLIB_BUILD_EXAMPLES=OFF' "$DEPS_DOCKERFILE" && ! grep -q -- 'ZLIB_BUILD_TESTING' "$DEPS_DOCKERFILE"; then
  sed -i 's/-DZLIB_BUILD_EXAMPLES=OFF/-DZLIB_BUILD_EXAMPLES=OFF -DZLIB_BUILD_TESTING=OFF/' "$DEPS_DOCKERFILE"
  echo "Patched $DEPS_DOCKERFILE: zlib tests disabled"
fi

# --- version (same derivation as .github/workflows/minimallib-publish.yml) ------------------
if [ -z "${NPM_VERSION:-}" ]; then
  CM="$STAGE/CMakeLists.txt"
  YEAR=$(grep -F 'set(RDKit_Year' "$CM" | cut -d'"' -f2)
  MONTH=$(grep -F 'set(RDKit_Month' "$CM" | cut -d'"' -f2); MONTH=$((10#$MONTH))
  REV=$(grep -F 'set(RDKit_Revision ' "$CM" | cut -d'"' -f2); REV=$((10#$REV))
  NPM_VERSION="${YEAR}.${MONTH}.${REV}"
  MOD=$(grep -F 'set(RDKit_RevisionModifier' "$CM" | cut -d'"' -f2 || true)
  if [ -n "$MOD" ]; then NPM_VERSION="${NPM_VERSION}-${MOD}"; fi
fi
echo "MinimalLib version: $NPM_VERSION"
export NPM_VERSION GET_SRC=copy

# --- build (RDKit's own script; ~20-30 min first time) ---------------------------------------
( cd "$STAGE/Code/MinimalLib" && bash scripts/build_rdkitjs.sh )

BUILT="$STAGE/Code/MinimalLib/build"
[ -f "$BUILT/dist/RDKit_minimal.wasm" ] || die "build finished but $BUILT/dist/RDKit_minimal.wasm is missing."

# --- test ------------------------------------------------------------------------------------
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  command -v node >/dev/null 2>&1 || die "node not found (set SKIP_TESTS=1 to skip tests)."
  echo "Running MinimalLib JS tests"
  ( cd "$STAGE" && node Code/MinimalLib/tests/tests.js )
fi

# --- collect ---------------------------------------------------------------------------------
rm -rf "$OUT"
cp -r "$BUILT" "$OUT"
if [ "${KEEP_STAGE:-0}" != "1" ]; then rm -rf "$STAGE"; fi
echo
echo "WASM build complete: $OUT"
ls -la "$OUT/dist" 2>/dev/null || true
