#!/bin/bash
# The whole release, in order: preflight, checks, build, notarize, verify, appcast, tag,
# upload. The upload is a draft: the maintainer checks it, then publishes it with
# --publish, which also puts the new appcast on the appcast branch, so users are offered
# the update only once the release is public.
#
#   scripts/release.sh --dry-run        preflight only; changes nothing
#   scripts/release.sh                  full release of the version in app.env
#   scripts/release.sh --notarize-only  resume: dist/ is built, notarization did not finish
#   scripts/release.sh --upload-only    resume: dist/ is final, only tag and upload remain
#   scripts/release.sh --publish        publish the checked draft and its appcast
#
# Only a package made from HEAD with a clean tree is tagged and uploaded (dist/BUILT_FROM,
# scripts/lib.sh). When dist/ already holds one, the full release uploads that very
# package, the one the hand checks were run on, instead of building another.
#
# Environment:
#   ALLOW_UNNOTARIZED=1   publish a build signed with the release certificate when there
#                         is no Developer ID (users approve the first launch; see README)
#   NOTARY_PROFILE        notarytool keychain profile (default: NOTARY_KEYCHAIN_PROFILE in app.env)
#   RELEASE_SIGN_IDENTITY override the Developer ID identity
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

MODE="${1:-full}"
case "$MODE" in full|--dry-run|--notarize-only|--upload-only|--publish) ;; *) die "unknown option: $MODE" ;; esac

TAG="V$VERSION"
IDENTITY="$(developer_id)"
NOTES=.github/RELEASE_NOTES.md
TOOLS="$(./scripts/sparkle.sh)/bin"

if [ "$MODE" = --publish ]; then
  stage publish
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
  grep -q "<sparkle:version>$BUILD</sparkle:version>" dist/appcast.xml 2>/dev/null \
    || die "dist/appcast.xml has no item for build $BUILD: run the release first"
  "$TOOLS/sign_update" --verify dist/appcast.xml >/dev/null || die "dist/appcast.xml is not signed with the update key"
  # The appcast signs dist/'s zip, so that must be the zip users download.
  DIGEST="$(gh api "repos/$REPOSITORY/releases" \
    --jq ".[] | select(.tag_name == \"$TAG\") | .assets[] | select(.name == \"$NAME.zip\") | .digest")"
  [ "$DIGEST" = "sha256:$(/usr/bin/shasum -a 256 "dist/$NAME.zip" | cut -d' ' -f1)" ] \
    || die "the $NAME.zip on the $TAG release is not dist/$NAME.zip"
  if [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = true ]; then
    gh release edit "$TAG" --draft=false
  fi
  # One commit on the appcast branch, made without touching the working tree.
  TREE="$(printf '100644 blob %s\tappcast.xml\n' "$(git hash-object -w dist/appcast.xml)" | git mktree)"
  PARENT="$(git ls-remote origin "refs/heads/$APPCAST_BRANCH" | cut -f1)"
  if [ -n "$PARENT" ]; then
    git fetch --quiet origin "$APPCAST_BRANCH"
    COMMIT="$(git commit-tree "$TREE" -p "$PARENT" -m "$TAG")"
  else
    COMMIT="$(git commit-tree "$TREE" -m "$TAG")"
  fi
  git push origin "$COMMIT:refs/heads/$APPCAST_BRANCH"
  echo "Published $TAG. Users who check for updates are offered it within minutes."
  exit 0
fi

stage preflight
PROBLEMS=()
problem() { PROBLEMS+=("$1"); printf '  ✗ %s\n' "$1"; }
ok() { printf '  ✓ %s\n' "$1"; }

[ "$(git branch --show-current)" = main ] && ok "on main" || problem "not on the main branch"
[ -z "$(git status --porcelain)" ] && ok "working tree clean" || problem "uncommitted changes"
if git remote get-url origin >/dev/null 2>&1; then
  case "$(git remote get-url origin)" in
    *"github.com/$REPOSITORY.git"|*"github.com/$REPOSITORY"|*"github.com:$REPOSITORY.git"|*"github.com:$REPOSITORY")
      ok "origin is $REPOSITORY" ;;
    *) problem "origin is not github.com/$REPOSITORY (REPOSITORY in app.env)" ;;
  esac
  git fetch --quiet origin main 2>/dev/null || true
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main 2>/dev/null || true)" ]; then
    ok "in sync with origin/main"
  else
    problem "HEAD is not origin/main: push first, the tag must point at a commit on GitHub"
  fi
  REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/$TAG" | cut -f1)"
  if [ -n "$REMOTE_TAG" ] && [ "$REMOTE_TAG" != "$(git rev-parse HEAD)" ]; then
    # An annotated tag lists its own object; compare what it points at.
    PEELED="$(git ls-remote --tags origin "refs/tags/$TAG^{}" | cut -f1)"
    [ "${PEELED:-$REMOTE_TAG}" = "$(git rev-parse HEAD)" ] \
      || problem "$TAG already exists on origin at another commit: bump the version, never move a tag"
  fi
else
  problem "no 'origin' remote: create the GitHub repository and push main first"
fi
gh auth status >/dev/null 2>&1 && ok "gh is logged in" || problem "gh is not logged in (gh auth login)"
if [ -z "$UPDATE_PUBLIC_KEY" ]; then
  problem "no UPDATE_PUBLIC_KEY in app.env: run scripts/make_update_key.sh once"
elif [ "$("$TOOLS/generate_keys" -p 2>/dev/null)" = "$UPDATE_PUBLIC_KEY" ]; then
  ok "the update key is in the keychain"
else
  problem "the update key is not in the keychain: restore it from its backup (generate_keys -f), never make a new one"
fi
PINNED="$(basename "$(dirname "$TOOLS")")"
LATEST="$(gh api repos/sparkle-project/Sparkle/releases/latest --jq .tag_name 2>/dev/null || true)"
[ -z "$LATEST" ] || [ "$PINNED" = "sparkle-$LATEST" ] \
  || printf '  ! Sparkle %s is out, the build uses %s (scripts/sparkle.sh); not required\n' "$LATEST" "${PINNED#sparkle-}"
./scripts/check_release_notes.sh >/dev/null 2>&1 && ok "release notes match $TAG" \
  || problem "release notes: run scripts/check_release_notes.sh"
./scripts/make_icon.sh --check >/dev/null 2>&1 && ok "icon files match Sources/App/AppMark.swift" \
  || problem "icon files are older than Sources/App/AppMark.swift: run make icon and commit"
if [ -n "$IDENTITY" ]; then
  ok "Developer ID certificate found"
  /usr/bin/xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-$NOTARY_KEYCHAIN_PROFILE}" >/dev/null 2>&1 \
    && ok "notarization profile works" \
    || problem "notarytool profile '${NOTARY_PROFILE:-$NOTARY_KEYCHAIN_PROFILE}' is missing or stale (see scripts/notarize.sh)"
else
  # Without a Developer ID, every release must carry the same self-signed certificate:
  # an ad-hoc build, or a new certificate, takes the screen-recording permission away
  # from every user who updates.
  if [ -z "$RELEASE_CERTIFICATE_SHA1" ]; then
    problem "no release certificate in app.env: run scripts/make_release_certificate.sh once"
  elif [ -n "$(release_certificate)" ]; then
    ok "release certificate '$RELEASE_CERTIFICATE' is in the keychain"
  else
    problem "the release certificate $RELEASE_CERTIFICATE_SHA1 is not in the keychain: import it from its backup, never make a new one"
  fi
  [ "${ALLOW_UNNOTARIZED:-0}" = 1 ] && ok "no Developer ID certificate; ALLOW_UNNOTARIZED=1, publishing an unnotarized build" \
    || problem "no Developer ID certificate: set ALLOW_UNNOTARIZED=1 to publish an unnotarized build on purpose"
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  printf '\nPreflight failed for %s (%d problem(s)). Nothing was changed.\n' "$TAG" "${#PROBLEMS[@]}"
  exit 1
fi
printf '\nPreflight passed for %s.\n' "$TAG"
[ "$MODE" = --dry-run ] && exit 0

if [ "$MODE" = full ]; then
  stage checks
  make check
  stage build
  if dist_is_releasable; then
    echo "Using dist/ as packaged from $(git rev-parse --short HEAD) on a clean tree: the package the hand checks saw."
  else
    echo "dist/ is not a clean package of HEAD: packaging again. The hand checks did not see this package."
    ./scripts/package.sh
  fi
fi

if [ "$MODE" != --upload-only ] && [ -n "$IDENTITY" ]; then
  stage notarize
  [ "$(cat "$BUILT_FROM" 2>/dev/null)" = "$(git rev-parse HEAD) clean" ] \
    || die "dist/ is not a clean package of HEAD; run the full release"
  ./scripts/notarize.sh
fi

stage verify
dist_is_releasable || die "dist/ is not a package of HEAD made with a clean tree, or its files changed after packaging ($BUILT_FROM: $(cat "$BUILT_FROM" 2>/dev/null || echo missing)). Nothing was tagged or uploaded."
echo "dist/ is a clean package of $(git rev-parse --short HEAD), unchanged since."

stage appcast
# The published appcast plus this release, signed; --publish puts it on the appcast branch.
PREVIOUS=""
if git ls-remote --exit-code origin "refs/heads/$APPCAST_BRANCH" >/dev/null; then
  git fetch --quiet origin "$APPCAST_BRANCH"
  PREVIOUS="$(mktemp)"
  git show "FETCH_HEAD:appcast.xml" > "$PREVIOUS"
elif [ $? -ne 2 ]; then
  die "could not read the $APPCAST_BRANCH branch on origin"
fi
ENCLOSURE="$("$TOOLS/sign_update" "dist/$NAME.zip")"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$ENCLOSURE")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$ENCLOSURE")"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || die "sign_update gave no signature: $ENCLOSURE"
python3 scripts/appcast.py "$PREVIOUS" dist/appcast.xml "$VERSION" "$BUILD" \
  "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "dist/$NAME.app/Contents/Info.plist")" \
  "https://github.com/$REPOSITORY/releases/download/$TAG/$NAME.zip" \
  "https://github.com/$REPOSITORY/releases/tag/$TAG" "$LENGTH" "$SIGNATURE" "$NOTES"
"$TOOLS/sign_update" dist/appcast.xml >/dev/null
echo "dist/appcast.xml offers $VERSION (build $BUILD)."

stage tag
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "local tag $TAG is not at HEAD"
else
  git tag -a "$TAG" -m "Release $TAG"
fi
git push origin "$TAG"

stage upload
TITLE="$(sed -n 's/^# //p' "$NOTES" | head -1)"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
sed '1{/^# /d;}' "$NOTES" > "$BODY"
ASSETS=("dist/$NAME.dmg" "dist/$NAME.zip" dist/SHA256SUMS)
# A draft is seen by the maintainer alone and is not releases/latest, so what users get
# can be looked at, downloaded and started before anyone else sees it.
if gh release view "$TAG" >/dev/null 2>&1; then
  [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = true ] \
    || die "$TAG is already published; a published release is never replaced"
  gh release edit "$TAG" --title "$TITLE" --notes-file "$BODY"
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  gh release create "$TAG" "${ASSETS[@]}" --draft --title "$TITLE" --notes-file "$BODY"
fi

URL="$(gh release view "$TAG" --json url --jq .url)"
cat <<END

Uploaded $TAG as a DRAFT: nobody else can see it yet. Before publishing it:
  1. Open $URL
     and read the notes in both languages; the logo and the links show.
  2. Download the disk image as a user would and check it:
       gh release download $TAG --pattern '*.dmg' --pattern SHA256SUMS --dir /tmp/$TAG
       (cd /tmp/$TAG && shasum -a 256 -c --ignore-missing SHA256SUMS)
     Start the app from it, on a Mac that did not build it if one is at hand.
  3. Publish it, which also offers it to users as an update:
       ./scripts/release.sh --publish
END
