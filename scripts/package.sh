#!/bin/bash
# Builds what a release ships, without publishing anything:
#
#   dist/<NAME>.app   universal (Apple silicon + Intel)
#   dist/<NAME>.dmg   the download: the app next to an Applications shortcut
#   dist/<NAME>.zip   the same app, for scripts and package managers
#   dist/SHA256SUMS
#   dist/BUILT_FROM            the commit, and whether the tree was clean (not uploaded)
#
# With a Developer ID certificate in the keychain the app is signed with it and the
# hardened runtime, ready for scripts/notarize.sh. Without one it is signed with the
# self-signed release certificate in app.env: macOS asks the user to approve it on the
# first launch, then keeps the screen-recording permission across updates. With
# neither it is signed ad hoc, fit for trying the package but not for a release (the
# preflight refuses it). `--archives-only` repacks an app that is already in dist/
# (after stapling, which changes the bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

APP=dist/$NAME.app
if [ "${1:-}" != "--archives-only" ]; then
  BEFORE="$(tree_state)"
  IDENTITY="$(developer_id)"
  SELF_SIGNED="$(release_certificate)"
  rm -rf dist
  if [ -n "$IDENTITY" ]; then
    ARCH=universal OUT_DIR=dist SIGN_IDENTITY="$IDENTITY" HARDENED=1 ./scripts/build.sh
  elif [ -n "$SELF_SIGNED" ]; then
    echo "No Developer ID certificate: signing with '$RELEASE_CERTIFICATE'. This build cannot be notarized."
    ARCH=universal OUT_DIR=dist SIGN_IDENTITY="$SELF_SIGNED" ./scripts/build.sh
  else
    echo "No Developer ID or release certificate: signing ad hoc. Not for a release."
    ARCH=universal OUT_DIR=dist SIGN_IDENTITY=- ./scripts/build.sh
  fi
fi
[ -d "$APP" ] || die "$APP does not exist"
# What keeps users' permissions from one release to the next: the requirement must name
# the certificate in app.env, whatever signed this build.
if [ -z "$(developer_id)" ] && [ -n "$(release_certificate)" ]; then
  /usr/bin/codesign -d -r- "$APP" 2>&1 | grep -qi "certificate leaf = H\"$RELEASE_CERTIFICATE_SHA1\"" \
    || die "$APP is not signed with the release certificate in app.env"
fi

/usr/bin/codesign --verify --deep --strict "$APP"
ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$NAME")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) die "expected a universal binary, got: $ARCHS" ;;
esac

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/$NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f dist/$NAME.dmg dist/$NAME.zip
/usr/bin/hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGING" \
  -format UDZO dist/$NAME.dmg
/usr/bin/ditto -c -k --keepParent "$STAGING/$NAME.app" dist/$NAME.zip
(cd dist && /usr/bin/shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
if [ -n "${BEFORE:-}" ]; then
  # Clean only if nothing changed while building either.
  if [ "$(tree_state)" = "$BEFORE" ]; then echo "$BEFORE" > "$BUILT_FROM"
  else echo "$(git rev-parse HEAD) dirty" > "$BUILT_FROM"; fi
fi

read -r FROM STATE < "$BUILT_FROM"
[ "$STATE" = clean ] && SOURCE="from ${FROM:0:7}" \
  || SOURCE="from ${FROM:0:7} with uncommitted changes, not for a release"
printf 'Packaged %s (%s), %s:\n' "$VERSION" "$ARCHS" "$SOURCE"
ls -lh dist/$NAME.dmg dist/$NAME.zip | awk '{print "  " $NF "  " $5}'
