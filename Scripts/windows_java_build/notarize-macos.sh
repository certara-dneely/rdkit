#!/usr/bin/env bash
# Submit the (already signed) macOS libraries to Apple's notary service and wait for the verdict.
#
#   notarize-macos.sh <dir> [<dir> ...]     notarizes every regular *.dylib / *.jnilib / *.so under the directories
#
# Env (all required): NOTARY_APPLE_ID, NOTARY_PASSWORD (app-specific password), NOTARY_TEAM_ID
#
# Notarization does not modify the files and a bare dylib cannot be stapled (stapler only handles .app, .pkg,
# .dmg): Gatekeeper finds the ticket online. Offline-proof distribution needs a signed .pkg/.dmg, stapled.
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: macOS only." >&2; exit 1; }
: "${NOTARY_APPLE_ID:?}" "${NOTARY_PASSWORD:?}" "${NOTARY_TEAM_ID:?}"
[ "$#" -ge 1 ] || { echo "usage: $0 <dir>..." >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/rdkit-libs.zip"

# zip with the directory layout, symlinks kept as symlinks (notarytool accepts a zip of Mach-O files)
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$@" -type f \( -name '*.dylib' -o -name '*.jnilib' -o -name '*.so' \) -print0)
[ "${#files[@]}" -gt 0 ] || { echo "ERROR: no libraries found under: $*" >&2; exit 1; }
# flat names would collide across directories, so each file goes under its index
i=0; mkdir "$WORK/pack"
for f in "${files[@]}"; do i=$((i + 1)); mkdir "$WORK/pack/$i"; cp "$f" "$WORK/pack/$i/"; done
( cd "$WORK/pack" && ditto -c -k --sequesterRsrc . "$ZIP" )
echo "submitting ${#files[@]} file(s) ($(( $(stat -f %z "$ZIP") / 1024 )) KB) for notarization..."

RESULT="$WORK/result.json"
set +e
xcrun notarytool submit "$ZIP" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" \
  --team-id "$NOTARY_TEAM_ID" --wait --timeout 60m --output-format json > "$RESULT"
rc=$?
set -e
cat "$RESULT" || true
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$RESULT" 2>/dev/null || true)"
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$RESULT" 2>/dev/null || true)"

if [ "$STATUS" != "Accepted" ]; then
  echo "ERROR: notarization status is '${STATUS:-unknown}' (notarytool exit $rc)" >&2
  if [ -n "$ID" ]; then
    xcrun notarytool log "$ID" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" >&2 || true
  fi
  exit 1
fi
echo "notarization Accepted (submission $ID)"
