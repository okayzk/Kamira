#!/bin/bash
# Sends dist/<NAME>.dmg to Apple for notarization, staples the ticket to the
# app and the disk image, and repacks the archives (stapling changes the app).
#
# Needs a Developer ID signature (scripts/package.sh) and a notarytool keychain
# profile: its name comes from NOTARY_PROFILE, default NOTARY_KEYCHAIN_PROFILE in app.env.
# Create it once, outside this repository:
#   xcrun notarytool store-credentials <NOTARY_KEYCHAIN_PROFILE>
# `--staple-only` skips the submission, for when Apple accepted but stapling failed.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

APP=dist/$NAME.app
DMG=dist/$NAME.dmg
PROFILE="${NOTARY_PROFILE:-$NOTARY_KEYCHAIN_PROFILE}"
[ -f "$DMG" ] && [ -d "$APP" ] || die "run scripts/package.sh first"
/usr/bin/codesign -dv "$APP" 2>&1 | grep -q 'Authority=Developer ID Application' \
  || die "$APP is not signed with a Developer ID certificate, so Apple will not notarize it"

if [ "${1:-}" != "--staple-only" ]; then
  # One retry: a failed upload leaves a submission that never finishes.
  /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    || /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    || die "notarization failed twice; check the network and the profile, then rerun"
fi
/usr/bin/xcrun stapler staple "$APP"
./scripts/package.sh --archives-only
/usr/bin/xcrun stapler staple "$DMG"
(cd dist && /usr/bin/shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
