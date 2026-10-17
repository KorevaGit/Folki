#!/bin/sh
set -eu

FOLKI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FOLKI_DERIVED_DATA="${FOLKI_DERIVED_DATA:-${TMPDIR:-/tmp}/FolkiDuoDerivedData}"

command -v xcodegen >/dev/null 2>&1 || {
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
}

cd "$FOLKI_ROOT"
swift test --package-path Core
xcodegen generate
for FOLKI_CONFIG in Debug Release Demo; do
  FOLKI_SCHEME=FolkiDuo
  if [ "$FOLKI_CONFIG" = Demo ]; then FOLKI_SCHEME=FolkiDuo-Demo; fi
  xcodebuild -quiet -project FolkiDuo.xcodeproj \
    -scheme "$FOLKI_SCHEME" -configuration "$FOLKI_CONFIG" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$FOLKI_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
done

echo "FolkiDuo: core tests and all three simulator configurations passed."
