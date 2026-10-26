#!/usr/bin/env bash
# Erzeugt die Release-Beschreibung: feste Notizen aus RELEASE_NOTES.md
# plus die Änderungen seit dem letzten Release-Tag.
# Aufruf: ci/release_notes.sh <Version> <Ausgabedatei>
set -euo pipefail
VERSION="$1"
OUT="$2"

sed "s/{{VERSION}}/$VERSION/g" RELEASE_NOTES.md > "$OUT"

PREV=$(git tag -l 'v1.0.*' --sort=-v:refname | grep -vx "v$VERSION" | head -1 || true)
if [ -n "$PREV" ]; then
  RANGE="$PREV..HEAD"
  TITLE="### Änderungen seit ${PREV#v}"
else
  RANGE="HEAD"
  TITLE="### Änderungen"
fi

# Nur eigene Commits, ohne Merge-Commits und Werkzeug-Commits
CHANGES=$(git log "$RANGE" --no-merges --pretty='- %s' \
  | grep -viE '^- (CI:|Diagnose:)' | head -40 || true)

if [ -n "$CHANGES" ]; then
  {
    echo
    echo "$TITLE"
    echo "$CHANGES"
  } >> "$OUT"
fi

echo "--- Release-Beschreibung ---"
cat "$OUT"
