#!/bin/bash
# Builds the app bundle.
#
#   scripts/build.sh                 development build for this Mac -> build/<NAME>.app
#   ARCH=universal OUT_DIR=dist ...  what a release ships (Apple silicon + Intel)
#
# Environment:
#   ARCH           native (default) | universal
#   OUT_DIR        where the bundle goes (default: build)
#   SIGN_IDENTITY  codesign identity; default "Apple Development" when the keychain has
#                  one, else ad-hoc ("-")
#   HARDENED=1     sign with the hardened runtime and entitlements (needed to notarize)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

ARCH="${ARCH:-native}"
OUT_DIR="${OUT_DIR:-build}"
MIN_OS=26.0
APP="$PWD/$OUT_DIR/$NAME.app"
BINARY="$APP/Contents/MacOS/$NAME"
FRAMEWORKS=(AppKit Carbon UniformTypeIdentifiers ScreenCaptureKit AVFoundation Vision Quartz ServiceManagement)

rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"
cp Bundle/Info.plist "$PLIST"
# The identity in app.env, so that no file in the repository repeats it.
set_key() { /usr/bin/plutil -insert "$1" -string "$2" "$PLIST"; }
set_key CFBundleName "$NAME"
set_key CFBundleDisplayName "$NAME"
set_key CFBundleExecutable "$NAME"
set_key CFBundleIdentifier "$BUNDLE_ID"
set_key CFBundleShortVersionString "$VERSION"
set_key CFBundleVersion "$BUILD"
set_key AppRepositoryURL "https://github.com/$REPOSITORY"
# Updates: Sparkle reads the signed appcast on the repository's appcast branch, written
# by scripts/release.sh. Checking on its own is off until the user turns it on.
[ -n "$UPDATE_PUBLIC_KEY" ] || die "no UPDATE_PUBLIC_KEY in app.env: run scripts/make_update_key.sh once"
set_key SUFeedURL "$APPCAST_URL"
set_key SUPublicEDKey "$UPDATE_PUBLIC_KEY"
/usr/bin/plutil -insert SUEnableAutomaticChecks -bool NO "$PLIST"
/usr/bin/plutil -insert SURequireSignedFeed -bool YES "$PLIST"
/usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
# The two languages' text tables and the icon, then the tagline each table takes
# from app.env.
cp -R Resources "$APP/Contents/Resources"
add_text() { # <language> <key> <text>
  local text="${3//\\/\\\\}"
  printf '"%s" = "%s";\n' "$2" "${text//\"/\\\"}" >> "$APP/Contents/Resources/$1.lproj/Localizable.strings"
}
add_text en about.tagline "$TAGLINE_EN"
add_text zh-Hans about.tagline "$TAGLINE_ZH"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

SPARKLE="$(./scripts/sparkle.sh)"
compile() { # <target triple or empty> <output>
  local args=(-swift-version 5 -O -F "$SPARKLE" -framework Sparkle
              -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
  [ -n "$1" ] && args+=(-target "$1")
  for framework in "${FRAMEWORKS[@]}"; do args+=(-framework "$framework"); done
  /usr/bin/xcrun swiftc "${args[@]}" "${SOURCES[@]}" -o "$2"
}

case "$ARCH" in
  native)
    compile "" "$BINARY"
    ;;
  universal)
    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "$SCRATCH"' EXIT
    compile "arm64-apple-macos$MIN_OS" "$SCRATCH/arm64"
    compile "x86_64-apple-macos$MIN_OS" "$SCRATCH/x86_64"
    /usr/bin/lipo -create "$SCRATCH/arm64" "$SCRATCH/x86_64" -output "$BINARY"
    ;;
  *)
    echo "ARCH must be native or universal, got: $ARCH" >&2
    exit 2
    ;;
esac

# A stable signature lets macOS keep the screen-recording permission across rebuilds;
# an ad-hoc one ("-") is a new app to the system every time.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if /usr/bin/security find-identity -v -p codesigning | grep -q '"Apple Development'; then
    IDENTITY="Apple Development"
  else
    IDENTITY="-"
  fi
fi
SIGN_FLAGS=(--force --sign "$IDENTITY")
[ -n "${SIGNING_KEYCHAIN:-}" ] && SIGN_FLAGS+=(--keychain "$SIGNING_KEYCHAIN")
[ "${HARDENED:-0}" = 1 ] && SIGN_FLAGS+=(--options runtime --timestamp)

# Sparkle, signed from the inside out with the app's identity (never --deep). The app is
# not sandboxed, so Sparkle's XPC services are left out, as its sandboxing guide allows.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE/Sparkle.framework" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"
for part in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
  /usr/bin/codesign "${SIGN_FLAGS[@]}" "$part"
done

[ "${HARDENED:-0}" = 1 ] && SIGN_FLAGS+=(--entitlements Bundle/Entitlements.plist)
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP"

printf 'Built: %s\n' "$APP"
