#!/bin/bash
# Shared by the build, packaging and release scripts. Run from the repository root.

# NAME, BUNDLE_ID, REPOSITORY, VERSION, BUILD, the taglines and the notary profile:
# the one place the app is named.
. ./app.env

# The version users see.
app_version() {
  printf '%s\n' "$VERSION"
}

# The Developer ID identity to sign a release with, or nothing when the keychain has
# none. RELEASE_SIGN_IDENTITY overrides the search.
developer_id() {
  if [ -n "${RELEASE_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$RELEASE_SIGN_IDENTITY"
    return
  fi
  /usr/bin/security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1
}

# The SHA-1 of the release certificate named in app.env when the keychain holds its
# identity, or nothing. Self-signed, so it is not "valid" to find-identity -v: look in all.
# SIGNING_KEYCHAIN points this, build.sh and make_release_certificate.sh at one keychain
# instead of the user's search list, for trying them without touching the login keychain.
release_certificate() {
  [ -n "$RELEASE_CERTIFICATE_SHA1" ] || return 0
  /usr/bin/security find-identity -p codesigning ${SIGNING_KEYCHAIN:+"$SIGNING_KEYCHAIN"} \
    | grep -qi " $RELEASE_CERTIFICATE_SHA1 " \
    && printf '%s\n' "$RELEASE_CERTIFICATE_SHA1" || true
}

# What dist/ was packaged from, written by package.sh as "<commit> clean" or
# "<commit> dirty". Dirty means the tree had uncommitted or untracked files: an untracked
# Swift file is compiled in too. Only a clean package of HEAD is ever released.
BUILT_FROM=dist/BUILT_FROM
tree_state() {
  local state=clean
  [ -z "$(git status --porcelain)" ] || state=dirty
  printf '%s %s\n' "$(git rev-parse HEAD)" "$state"
}
# Succeeds when dist/ is a clean package of HEAD whose files are unchanged since.
dist_is_releasable() {
  [ -f "$BUILT_FROM" ] && [ "$(cat "$BUILT_FROM")" = "$(git rev-parse HEAD) clean" ] \
    && (cd dist && /usr/bin/shasum -a 256 -s -c SHA256SUMS)
}

stage() { printf '\n[stage:%s]\n' "$1"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Where Sparkle looks for updates: appcast.xml on the repository's appcast branch, kept
# off main so that main's history holds only changes to the app.
APPCAST_BRANCH=appcast
APPCAST_URL="https://raw.githubusercontent.com/$REPOSITORY/$APPCAST_BRANCH/appcast.xml"
