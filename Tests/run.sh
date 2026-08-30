#!/usr/bin/env bash
# █ dcj · dotcomjack.com · MIT
#
# Builds and runs the Follow Focus tests.
#
# Deliberately not an XCTest target. Everything under test is Foundation-only so
# that it needs no host app and no run loop owned by AppKit, which keeps this to
# one swiftc invocation on a clean clone.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/focus-tests"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> Building tests"
swiftc -O \
  Sources/ClockMode.swift \
  Sources/FocusEngagement.swift \
  Tests/main.swift \
  -o "$OUT"

echo "==> Running"
"$OUT"
