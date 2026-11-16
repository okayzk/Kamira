#!/bin/bash
# Opens each surface of the built app in its demo mode and checks what assistive apps
# (VoiceOver, Voice Control, AI agents) can read there; see accessibility_audit.swift.
# Its windows appear briefly but take no focus, keys or clicks (`--quiet`); `--all` also
# reads the recording selector, which dims every screen meanwhile. Not part of
# `make check`: it needs a built app, a screen and the Accessibility permission.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
APP="build/$NAME.app"
[ -d "$APP" ] || ./scripts/build.sh
mkdir -p build
/usr/bin/xcrun swiftc -swift-version 5 scripts/accessibility_audit.swift -o build/accessibility_audit
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
build/accessibility_audit "$APP/Contents/MacOS/$NAME" "$WORK" "$@"
