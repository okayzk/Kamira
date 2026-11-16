#!/bin/bash
# Holds the source tree to its one rule: a feature folder under Sources/ uses only its
# own code and Sources/Shared/; features are joined by Sources/App/ through callbacks.
# The compiler is the judge: Shared/ must build on its own, and each feature folder
# with Shared/ and nothing else. A type taken from another feature fails to compile.
#
# Usage: check_structure.sh [--jobs N] [--all]
#   Checks the feature folders the uncommitted changes touch (with a clean tree, the
#   last commit's), all of them when Shared/ changed, none when only App/ did.
#   --jobs N  how many folders are checked at once (default: half the processors)
#   --all     every folder, whatever changed (the release preflight)
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE="$(./scripts/sparkle.sh)"

shared_files() { find Sources/Shared -name '*.swift' | sort; }

# The first errors of compiling the given files, nothing when they compile.
typecheck() {
  /usr/bin/xcrun swiftc -typecheck -swift-version 5 -F "$SPARKLE" "$@" 2>&1 \
    | grep -E "error:" | grep -v "^ *|" | head -5 || true
}

# One feature folder with Shared/; run by xargs below, one process per folder.
if [ "${1:-}" = --one ]; then
  files=()
  while IFS= read -r file; do files+=("$file"); done < <(shared_files; find "Sources/$2" -name '*.swift' | sort)
  out="$(typecheck "${files[@]}")"
  [ -z "$out" ] && exit 0
  printf '%s/ uses more than itself and Shared/:\n%s\n' "$2" "$out"
  exit 1
fi

jobs=$(( $(sysctl -n hw.ncpu) / 2 ))
all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs="$2"; shift 2 ;;
    --all) all=1; shift ;;
    *) echo "usage: $0 [--jobs N] [--all]" >&2; exit 2 ;;
  esac
done
[ "$jobs" -ge 1 ] || jobs=1

features=()
for dir in Sources/*/; do
  name="$(basename "$dir")"
  if [ "$name" != App ] && [ "$name" != Shared ]; then features+=("$name"); fi
done

# The folders under Sources/ that changed: uncommitted (both sides of a rename), or
# with a clean tree the last commit.
changed="$(git status --porcelain -- Sources | sed -E 's/^.. //; s/ -> /\n/')"
[ -n "$changed" ] || changed="$(git diff --name-only HEAD~1 HEAD -- Sources)"
folders="$(printf '%s\n' "$changed" | sed -nE 's|^"?Sources/([^/]+)/.*|\1|p' | sort -u)"

if [ "$all" = 1 ] || printf '%s\n' "$folders" | grep -qx Shared; then
  check=("${features[@]}")
else
  check=()
  for name in "${features[@]}"; do
    if printf '%s\n' "$folders" | grep -qx "$name"; then check+=("$name"); fi
  done
fi

shared=()
while IFS= read -r file; do shared+=("$file"); done < <(shared_files)
out="$(typecheck "${shared[@]}")"
if [ -n "$out" ]; then
  printf 'Shared/ does not build on its own:\n%s\n' "$out"
  exit 1
fi
if [ ${#check[@]} -eq 0 ]; then
  echo "Structure holds: Shared/ builds on its own; no feature folder changed."
  exit 0
fi
printf '%s\n' "${check[@]}" | xargs -P "$jobs" -I{} "$0" --one {} \
  || exit 1
echo "Structure holds: Shared/ builds on its own, and so do ${check[*]} with it ($jobs at a time)."
