#!/bin/sh
set -eu

FOLKI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FOLKI_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FOLKI_SIM_ARCH=$(uname -m)
FOLKI_CACHE="${TMPDIR:-/tmp}/folki-duo-swift-module-cache"

mkdir -p "$FOLKI_CACHE"
xcrun swiftc -typecheck \
  -target "${FOLKI_SIM_ARCH}-apple-ios26.0-simulator" \
  -sdk "$FOLKI_SDK" \
  -module-cache-path "$FOLKI_CACHE" \
  "$FOLKI_ROOT/Prototype/FolkiHealthConcept.swift"

echo "FolkiDuo: SwiftUI prototype typecheck passed."
