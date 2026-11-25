#!/bin/bash
# Все тесты macOS: юнит-тесты логики + интеграционные тесты установки.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "### macOS: юнит-тесты"
xcrun swiftc -parse-as-library -o "$BUILD/unit" "$REPO/macos/Core.swift" "$REPO/macos/Parsers.swift" "$REPO/macos/Monitoring.swift" "$REPO/tests/macos/UnitTests.swift" || exit 1
"$BUILD/unit"; unit=$?

echo ""
echo "### macOS: интеграционные тесты"
bash "$REPO/tests/macos/integration.sh"; integ=$?

[ $unit -eq 0 ] && [ $integ -eq 0 ]
