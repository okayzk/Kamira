#!/bin/bash
# Prints the folder of the pinned Sparkle release (Sparkle.framework, bin/), downloading
# it into .tmp/ the first time. Sparkle installs updates; it is the app's one dependency.
#
# To move to a newer Sparkle: change the two lines below, then update a copy of the last
# release to a build made with it before committing.
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

DIR="$PWD/.tmp/sparkle-$SPARKLE_VERSION"
if [ ! -d "$DIR/Sparkle.framework" ]; then
  mkdir -p .tmp
  ARCHIVE=".tmp/Sparkle-$SPARKLE_VERSION.tar.xz"
  /usr/bin/curl -fsSL -o "$ARCHIVE" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $ARCHIVE" | /usr/bin/shasum -a 256 -c -s \
    || { rm -f "$ARCHIVE"; echo "error: $ARCHIVE does not match its pinned SHA-256" >&2; exit 1; }
  rm -rf "$DIR.partial" && mkdir "$DIR.partial"
  /usr/bin/tar -xf "$ARCHIVE" -C "$DIR.partial" Sparkle.framework bin
  mv "$DIR.partial" "$DIR" && rm -f "$ARCHIVE"
fi
printf '%s\n' "$DIR"
