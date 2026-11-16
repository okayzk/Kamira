#!/bin/bash
# Holds the source tree to its one rule: a feature folder under Sources/ uses only its
# own code and Sources/Shared/; features are joined by Sources/App/ through callbacks.
# The compiler is the judge: Shared/ must build on its own, and each feature folder
# with Shared/ and nothing else. A type taken from another feature fails to compile.
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE="$(./scripts/sparkle.sh)"
typecheck() {
  /usr/bin/xcrun swiftc -typecheck -swift-version 5 -F "$SPARKLE" "$@" 2>&1 | grep -E "error:" | grep -v "^ *|" | head -5 || true
}

shared=()
if [ -d Sources/Shared ]; then
  while IFS= read -r file; do shared+=("$file"); done < <(find Sources/Shared -name '*.swift' | sort)
fi
problems=0
if [ ${#shared[@]} -gt 0 ]; then
  out="$(typecheck "${shared[@]}")"
  if [ -n "$out" ]; then echo "Shared/ does not build on its own:"; echo "$out"; problems=1; fi
fi
features=0
for dir in Sources/*/; do
  name="$(basename "$dir")"
  if [ "$name" = App ] || [ "$name" = Shared ]; then continue; fi
  features=$((features + 1))
  files=()
  while IFS= read -r file; do files+=("$file"); done < <(find "$dir" -name '*.swift' | sort)
  out="$(typecheck "${shared[@]+"${shared[@]}"}" "${files[@]}")"
  if [ -n "$out" ]; then echo "$name/ uses more than itself and Shared/:"; echo "$out"; problems=1; fi
done
[ "$problems" = 0 ] || exit 1
echo "Structure holds: Shared/ and $features feature folders each build on their own."
