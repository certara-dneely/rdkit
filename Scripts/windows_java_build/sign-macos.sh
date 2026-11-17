#!/usr/bin/env bash
# Code-sign the macOS libraries (Developer ID, hardened runtime, secure timestamp: what notarization needs).
#
#   sign-macos.sh <dir> [<dir> ...]    signs every regular *.dylib / *.jnilib / *.so under the directories
#                                      (symlinks are skipped: they point at the file that gets signed)
#
# Env: SIGN_IDENTITY (required: certificate name, e.g. "Certara USA, Inc."),
#      KEYCHAIN       (optional: keychain holding the identity; default = the user's search list)
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: macOS only." >&2; exit 1; }
: "${SIGN_IDENTITY:?SIGN_IDENTITY is required}"
[ "$#" -ge 1 ] || { echo "usage: $0 <dir>..." >&2; exit 1; }

KC_ARGS=(); [ -n "${KEYCHAIN:-}" ] && KC_ARGS=(--keychain "$KEYCHAIN")

n=0
while IFS= read -r -d '' f; do
  codesign --force --timestamp --options runtime "${KC_ARGS[@]}" --sign "$SIGN_IDENTITY" "$f"
  codesign --verify --strict --verbose=1 "$f"
  # hardened runtime flag + timestamp must be present or notarization rejects the file
  info="$(codesign -dvv "$f" 2>&1)"
  echo "$info" | grep -q 'flags=.*runtime' || { echo "ERROR: $f was not signed with the hardened runtime" >&2; exit 1; }
  echo "$info" | grep -q '^Timestamp=' || { echo "ERROR: $f has no secure timestamp" >&2; exit 1; }
  echo "signed: $f   ($(echo "$info" | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1))"
  n=$((n + 1))
done < <(find "$@" -type f \( -name '*.dylib' -o -name '*.jnilib' -o -name '*.so' \) -print0)

[ "$n" -gt 0 ] || { echo "ERROR: no libraries found under: $*" >&2; exit 1; }
echo "signed $n file(s)"
