#!/usr/bin/env bash
# Build the Linux x86_64 RDKit libraries + Java wrapper (libGraphMolWrap.so, org.RDKit.jar) + InChI
# inside a Docker container, from a clean LF export of the COMMITTED source (git HEAD).
# Output: $BUILDROOT/linux/install (C++ libs + headers) and $BUILDROOT/linux/java-dist
# Targets RHEL 9 (AlmaLinux 9 image). Requires Docker Desktop in Linux-containers mode.
# Optional env: BUILDROOT, BASE_IMAGE (default almalinux:9), JOBS (default 8; ~2 GB RAM each), BOOST_VERSION/SWIG_VERSION via Dockerfile args, KEEP_STAGE=1, DEPS_CACHE_DIR (cache SWIG+Boost layers there; CI)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

BUILDROOT="${BUILDROOT:-C:/Projects/builds/rdkit}"
if command -v cygpath >/dev/null 2>&1; then BUILDROOT="$(cygpath -u "$BUILDROOT")"; fi
LINUX_ROOT="$BUILDROOT/linux"
CTX="$LINUX_ROOT/ctx"
BASE_IMAGE="${BASE_IMAGE:-almalinux:9}"
JOBS="${JOBS:-8}"   # RDKit TUs are memory hungry: keep JOBS * ~2 GB below Docker's memory limit

die() { echo "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
docker info >/dev/null 2>&1 || die "Docker engine not reachable. Start Docker Desktop and re-run."
[ "$(docker info --format '{{.OSType}}' 2>/dev/null)" = "linux" ] \
  || die "Docker is in Windows-containers mode. Switch Docker Desktop to Linux containers."

if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  echo "NOTE: uncommitted changes to tracked files exist; they are NOT included (building HEAD)."
fi

echo "Staging committed source to $CTX"
rm -rf "$CTX"; mkdir -p "$CTX/src"
git -C "$REPO" -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD | tar -x -C "$CTX/src"
cp -r "$HERE/smoke" "$CTX/smoke"

# Export as a tar archive, not a directory: the install tree contains .so symlinks, which Windows
# cannot create without elevated privileges ("A required privilege is not held by the client").
# The tar keeps them intact, which is what you want to deploy to Linux anyway.
TARBALL="$LINUX_ROOT/rdkit-linux-x86_64.tar"
rm -f "$TARBALL" "$TARBALL.gz"
COMMON_ARGS=(-f "$HERE/linux/Dockerfile" --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "JOBS=$JOBS")
CACHE_FROM=()
if [ -n "${DEPS_CACHE_DIR:-}" ]; then
  # Cache the slow-to-build, source-independent layers (SWIG + Boost) in DEPS_CACHE_DIR, so CI can keep
  # it with actions/cache. Needs a buildx builder with the docker-container driver
  # (docker/setup-buildx-action), because the default docker driver cannot import/export a local cache.
  mkdir -p "$DEPS_CACHE_DIR"
  DEPS_CACHE_DIR="$(cd "$DEPS_CACHE_DIR" && pwd)"
  rm -rf "$DEPS_CACHE_DIR.new"
  docker buildx build "${COMMON_ARGS[@]}" --target deps \
    --cache-from "type=local,src=$DEPS_CACHE_DIR" \
    --cache-to "type=local,dest=$DEPS_CACHE_DIR.new,mode=max" \
    --output type=cacheonly "$CTX"
  rm -rf "$DEPS_CACHE_DIR"; mv "$DEPS_CACHE_DIR.new" "$DEPS_CACHE_DIR"
  CACHE_FROM=(--cache-from "type=local,src=$DEPS_CACHE_DIR")
fi
DOCKER_BUILDKIT=1 docker build "${COMMON_ARGS[@]}" --target export ${CACHE_FROM[@]+"${CACHE_FROM[@]}"} \
  -o "type=tar,dest=$(cygpath -m "$TARBALL" 2>/dev/null || echo "$TARBALL")" "$CTX"
gzip -f "$TARBALL"
TARBALL="$TARBALL.gz"

# java-dist has no symlinks, so extract it for convenience; install/ stays inside the archive.
rm -rf "$LINUX_ROOT/java-dist"
tar -xzf "$TARBALL" -C "$LINUX_ROOT" java-dist
if [ "${KEEP_STAGE:-0}" != "1" ]; then rm -rf "$CTX"; fi

echo
echo "Linux build complete:"
echo "  Everything (install/ C++ libs + headers, java-dist/): $TARBALL"
echo "    deploy: tar -xzf $(basename "$TARBALL")   (preserves the .so symlinks)"
echo "  Java deliverables, extracted : $LINUX_ROOT/java-dist"
echo "  Needs glibc >= $(cat "$LINUX_ROOT/java-dist/min-glibc.txt" 2>/dev/null | sed 's/GLIBC_//')"
