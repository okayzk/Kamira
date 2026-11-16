#!/bin/bash
# Opens each surface of the built app in its demo mode and checks what assistive apps
# (VoiceOver, Voice Control, AI agents) can read there; see accessibility_audit.swift.
# Its windows appear briefly but take no focus, keys or clicks (`--quiet`); `--all` also
# reads the recording selector, which dims every screen meanwhile. Not part of
# `make check`: it needs a built app, a screen and the Accessibility permission.
# The last run's output is kept in build/accessibility_audit.log: a failure can depend on
# timing and not come back on a second run.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
APP="build/$NAME.app"
[ -d "$APP" ] || ./scripts/build.sh
mkdir -p build
/usr/bin/xcrun swiftc -swift-version 5 scripts/accessibility_audit.swift -o build/accessibility_audit
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG=build/accessibility_audit.log
{ date; git log --oneline -1; } > "$LOG"
# pipefail (set above) keeps the audit's own exit status through tee.
build/accessibility_audit "$APP/Contents/MacOS/$NAME" "$WORK" "$@" 2>&1 | tee -a "$LOG"
