#!/bin/sh
set -eu

FOLKI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FOLKI_DERIVED_DATA="${FOLKI_DERIVED_DATA:-${TMPDIR:-/tmp}/FolkiDerivedData}"

command -v xcodegen >/dev/null 2>&1 || {
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
}

cd "$FOLKI_ROOT"
swift test --package-path Core
# Every string in use needs an English translation; a key without one shows Russian in the English app.
python3 -I - App/Resources/Localizable.xcstrings Widgets/Localizable.xcstrings \
  Core/Sources/FolkiDuoCore/Resources/Localizable.xcstrings Core/Sources/FolkiDuoPersistence/Resources/Localizable.xcstrings <<'PY'
import json, sys
missing = [(path, key) for path in sys.argv[1:] for key, value in json.load(open(path))["strings"].items()
           if value.get("extractionState") != "stale" and value.get("shouldTranslate", True)
           and "en" not in value.get("localizations", {})]
for path, key in missing: print(f"{path}: no English for {key!r}", file=sys.stderr)
sys.exit(1 if missing else 0)
PY
# Screens use DesignTokens.swift: no raw text styles, point sizes or RGB colours outside the token files.
# Illustrations mark a deliberate exception with "token-exempt" on the line.
FOLKI_RAW_STYLES=$(grep -nE '\.font\(\.|Font\.system|\.system\(size:|Color\(red:|RingPalette\.(personal|family)\.start' App/Sources/*.swift \
  | grep -vE '^App/Sources/(Theme|DesignTokens|CategoryViews|FamilyBubbles)\.swift:' | grep -v 'token-exempt' || true)
if [ -n "$FOLKI_RAW_STYLES" ]; then
  echo "$FOLKI_RAW_STYLES" >&2
  echo "Use FolkiFont, FolkiTextRole and the colour tokens from DesignTokens.swift." >&2
  exit 1
fi
xcodegen generate
for FOLKI_CONFIG in Debug Release Demo Cloud; do
  FOLKI_SCHEME=Folki
  if [ "$FOLKI_CONFIG" = Demo ]; then FOLKI_SCHEME=Folki-Demo; fi
  if [ "$FOLKI_CONFIG" = Cloud ]; then FOLKI_SCHEME=Folki-iCloud; fi
  xcodebuild -quiet -project Folki.xcodeproj \
    -scheme "$FOLKI_SCHEME" -configuration "$FOLKI_CONFIG" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$FOLKI_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
done

echo "Folki: core tests and all four simulator configurations passed."
