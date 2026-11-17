#!/usr/bin/env bash
# Publish the WASM MinimalLib build (RDKit_minimal.js / .wasm / .d.ts) to JFrog as ONE Maven coordinate.
# Credentials come from the Maven server entry <id>$JFROG_REPO_ID</id> in settings.xml (never read or
# printed by this script).
#
#   org.rdkit:rdkit-minimallib:<version>
#     .pom
#     .zip            the whole build folder (dist/ + package.json + README + GettingStartedInJS.html)
#     -js.js          dist/RDKit_minimal.js
#     -wasm.wasm      dist/RDKit_minimal.wasm
#     -types.d.ts     dist/RDKit_minimal.d.ts
#
# Input: $BUILDROOT/wasm/build (output of build-wasm.sh).
# Env: BUILDROOT, VERSION (default: RDKit version from CMakeLists.txt, e.g. 2026.09.2, same as the Java
#      artifact), JFROG_REPO_ID (certara-jfrog-admin), JFROG_URL, DRY_RUN=1 (print only)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILDROOT="${BUILDROOT:-C:/Projects/builds/rdkit}"
command -v cygpath >/dev/null 2>&1 && BUILDROOT="$(cygpath -u "$BUILDROOT")"
if [ -z "${VERSION:-}" ]; then
  cm="$REPO/CMakeLists.txt"
  y=$(grep -F 'set(RDKit_Year' "$cm" | cut -d'"' -f2); m=$(grep -F 'set(RDKit_Month' "$cm" | cut -d'"' -f2)
  r=$(grep -F 'set(RDKit_Revision ' "$cm" | cut -d'"' -f2); mod=$(grep -F 'set(RDKit_RevisionModifier' "$cm" | cut -d'"' -f2 || true)
  VERSION="$y.$m.$r"; if [ -n "$mod" ]; then VERSION="$VERSION-$mod"; fi
fi
JFROG_REPO_ID="${JFROG_REPO_ID:-certara-jfrog-admin}"
JFROG_URL="${JFROG_URL:-https://certara.jfrog.io/artifactory/certara-maven-develop-local}"
GROUP=org.rdkit; ARTIFACT=rdkit-minimallib

B="$BUILDROOT/wasm/build"; D="$B/dist"
FILES=("$D/RDKit_minimal.js" "$D/RDKit_minimal.wasm" "$D/RDKit_minimal.d.ts")
CLASSIFIERS=(js wasm types)
TYPES=(js wasm d.ts)
for f in "${FILES[@]}" "$B/package.json"; do [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }; done

w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }   # native path for java/mvn on Windows
WORK="$(mktemp -d)"
ZIP="$WORK/rdkit-minimallib-$VERSION.zip"
( cd "$B" && jar --create --no-manifest --file "$(w "$ZIP")" . )

POM="$WORK/pom.xml"
cat > "$POM" <<POMEOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$GROUP</groupId>
  <artifactId>$ARTIFACT</artifactId>
  <version>$VERSION</version>
  <packaging>zip</packaging>
  <name>RDKit MinimalLib (WebAssembly / JavaScript)</name>
  <description>RDKit $VERSION MinimalLib compiled to WebAssembly with Emscripten, built from the Certara fork. The zip is the npm-style package folder (dist/ with RDKit_minimal.js, .wasm and .d.ts, plus package.json); the js, wasm and types classifiers are the individual files. Includes InChI.</description>
  <url>https://github.com/rdkit/rdkit</url>
  <licenses><license><name>BSD 3-Clause</name><url>https://github.com/rdkit/rdkit/blob/master/license.txt</url></license></licenses>
</project>
POMEOF

join() { local IFS=,; echo "$*"; }
WFILES=(); for f in "${FILES[@]}"; do WFILES+=("$(w "$f")"); done
CMD=(mvn -B deploy:deploy-file
  "-DrepositoryId=$JFROG_REPO_ID" "-Durl=$JFROG_URL"
  "-Dfile=$(w "$ZIP")" -DpomFile="$(w "$POM")" -Dpackaging=zip
  "-Dfiles=$(join "${WFILES[@]}")" "-Dclassifiers=$(join "${CLASSIFIERS[@]}")" "-Dtypes=$(join "${TYPES[@]}")")

echo "Target : $JFROG_URL  (server id: $JFROG_REPO_ID)"
echo "Publish: $GROUP:$ARTIFACT:$VERSION"
printf '  %-10s %-5s %6s KB  %s\n' "(main)" zip "$(( $(stat -c %s "$ZIP") / 1024 ))" "$(basename "$ZIP")"
for i in "${!FILES[@]}"; do printf '  %-10s %-5s %6s KB  %s\n' "${CLASSIFIERS[$i]}" "${TYPES[$i]}" \
  "$(( $(stat -c %s "${FILES[$i]}") / 1024 ))" "$(basename "${FILES[$i]}")"; done
if [ "${DRY_RUN:-0}" = "1" ]; then echo "(dry run: nothing uploaded)"; rm -rf "$WORK"; exit 0; fi
"${CMD[@]}"
rm -rf "$WORK"
