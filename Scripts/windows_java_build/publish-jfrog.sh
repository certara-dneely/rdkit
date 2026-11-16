#!/usr/bin/env bash
# Publish the Windows + Linux RDKit Java artifacts to JFrog as ONE Maven coordinate with per-platform
# classifiers. Credentials come from the Maven server entry <id>$JFROG_REPO_ID</id> in settings.xml
# (never read or printed by this script).
#
#   org.rdkit:rdkit-java:<version>
#     .pom  .jar                        (main jar = the Windows-built jar; compile against this)
#     -windows-x64.jar   -windows-x64.dll   -windows-x64-install.zip
#     -linux-x86_64.jar  -linux-x86_64.so   -linux-x86_64-install.tar.gz
#     -macos-arm64.* / -macos-x86_64.*  (jar, dylib, install tar.gz; only if built)
#
# The Windows and Linux jars differ in 6 API points: C++ `long` is 32-bit on Windows and 64-bit on
# Linux, so SWIG generates `int use_count()` vs `long use_count()` on Shared_Int_Array/Shared_Double_Array
# and 4 differently named opaque SWIGTYPE_p_* classes (one reachable via
# RDKFuncs.getUnfoldedRDKFingerprintMol). Core functionality works when either jar is paired with either
# native library (tested), but code compiled against one jar fails with NoSuchMethodError on the other,
# so compile and run against the SAME jar. The main jar is the Windows one (`int use_count()` is ABI-safe
# against both native libraries). Use the classifier jar that matches the native library when in doubt.
#
# NOTE: 2026.09.2 itself was published in two steps (pom-packaged pom + classifiers, then the main jar
# added with -DgeneratePom=false); this script publishes the same layout in one call for new versions.
#
# Env: BUILDROOT, VERSION, MAIN_JAR (jar for the plain artifact), JFROG_REPO_ID (certara-jfrog-admin), JFROG_URL, DRY_RUN=1 (print only)
set -euo pipefail

BUILDROOT="${BUILDROOT:-C:/Projects/builds/rdkit}"
command -v cygpath >/dev/null 2>&1 && BUILDROOT="$(cygpath -u "$BUILDROOT")"
VERSION="${VERSION:-2026.09.2}"
JFROG_REPO_ID="${JFROG_REPO_ID:-certara-jfrog-admin}"
JFROG_URL="${JFROG_URL:-https://certara.jfrog.io/artifactory/certara-maven-develop-local}"
GROUP=org.rdkit; ARTIFACT=rdkit-java

W="$BUILDROOT/java-dist"; L="$BUILDROOT/linux/java-dist"
FILES=(
  "$W/org.RDKit.jar"                           "$W/GraphMolWrap.dll"
  "$BUILDROOT/rdkit-windows-x64-install.zip"
  "$L/org.RDKit.jar"                           "$L/libGraphMolWrap.so"
  "$BUILDROOT/linux/rdkit-linux-x86_64.tar.gz"
)
CLASSIFIERS=(windows-x64 windows-x64 windows-x64-install linux-x86_64 linux-x86_64 linux-x86_64-install)
TYPES=(jar dll zip jar so tar.gz)
# macOS builds (from the GitHub workflows) are added when present: $BUILDROOT/macos-<arch>/...
for A in arm64 x86_64; do
  M="$BUILDROOT/macos-$A"
  if [ -f "$M/java-dist/libGraphMolWrap.dylib" ]; then
    FILES+=("$M/java-dist/org.RDKit.jar" "$M/java-dist/libGraphMolWrap.dylib" "$M/rdkit-macos-$A-install.tar.gz")
    CLASSIFIERS+=("macos-$A" "macos-$A" "macos-$A-install")
    TYPES+=(jar dylib tar.gz)
  fi
done
# Jar published as the plain (no classifier) artifact; default = the Windows-built jar.
MAIN_JAR="${MAIN_JAR:-$W/org.RDKit.jar}"
[ -f "$MAIN_JAR" ] || { echo "ERROR: missing MAIN_JAR $MAIN_JAR" >&2; exit 1; }

for f in "${FILES[@]}"; do [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }; done

POM="$(mktemp -d)/pom.xml"
cat > "$POM" <<POMEOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$GROUP</groupId>
  <artifactId>$ARTIFACT</artifactId>
  <version>$VERSION</version>
  <packaging>jar</packaging>
  <name>RDKit Java wrapper (native)</name>
  <description>RDKit $VERSION C++ libraries and SWIG Java wrapper with InChI, built from the Certara fork. Main jar = the common Java API (see the MAIN_JAR note in publish-jfrog.sh). Native libraries are classifiers: windows-x64 (dll; MSVC, loads on JDK 21+), linux-x86_64 (so; built on AlmaLinux 9 for RHEL 9, glibc 2.34, needs system freetype) and, when built, macos-arm64 / macos-x86_64 (dylib); each platform also has a classifier jar and an *-install archive with C++ libs and headers. The Windows and Linux jars differ in a few API points (use_count() int vs long, opaque SWIGTYPE class names): compile and run against the same jar.</description>
  <url>https://github.com/rdkit/rdkit</url>
  <licenses><license><name>BSD 3-Clause</name><url>https://github.com/rdkit/rdkit/blob/master/license.txt</url></license></licenses>
</project>
POMEOF

join() { local IFS=,; echo "$*"; }
WFILES=(); for f in "${FILES[@]}"; do WFILES+=("$(cygpath -m "$f" 2>/dev/null || echo "$f")"); done
CMD=(mvn -B deploy:deploy-file
  "-DrepositoryId=$JFROG_REPO_ID" "-Durl=$JFROG_URL"
  "-Dfile=$(cygpath -m "$MAIN_JAR" 2>/dev/null || echo "$MAIN_JAR")" -DpomFile="$(cygpath -m "$POM" 2>/dev/null || echo "$POM")" -Dpackaging=jar
  "-Dfiles=$(join "${WFILES[@]}")" "-Dclassifiers=$(join "${CLASSIFIERS[@]}")" "-Dtypes=$(join "${TYPES[@]}")")

echo "Target : $JFROG_URL  (server id: $JFROG_REPO_ID)"
echo "Publish: $GROUP:$ARTIFACT:$VERSION"
for i in "${!FILES[@]}"; do printf '  %-22s %-5s %6s MB  %s\n' "${CLASSIFIERS[$i]}" "${TYPES[$i]}" \
  "$(( $(stat -c %s "${FILES[$i]}") / 1048576 ))" "$(basename "${FILES[$i]}")"; done
if [ "${DRY_RUN:-0}" = "1" ]; then echo "(dry run: nothing uploaded)"; exit 0; fi
"${CMD[@]}"
