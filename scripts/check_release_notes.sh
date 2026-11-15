#!/bin/bash
# The release notes become the GitHub Release as they are, so their shape is checked:
# the title names the version in app.env, and the English and Chinese lists
# are both there with the same number of items, each "N. **Label**: sentence".
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

NOTES=.github/RELEASE_NOTES.md
grep -Eq "^# V${VERSION//./\\.} [A-Z][A-Za-z]+$" <(head -1 "$NOTES") \
  || die "$NOTES must start with '# V$VERSION <Codename>', found: $(head -1 "$NOTES")"

items() { # <section heading>: prints that section's numbered lines
  awk -v heading="$1" '$0 == heading {on = 1; next} /^### / {on = 0} on && /^[0-9]+\. /' "$NOTES"
}
ENGLISH="$(items '### Changelog')"
CHINESE="$(items '### 更新日志')"
[ -n "$ENGLISH" ] || die "$NOTES has no numbered items under '### Changelog'"
[ -n "$CHINESE" ] || die "$NOTES has no numbered items under '### 更新日志'"
[ "$(printf '%s\n' "$ENGLISH" | wc -l)" -eq "$(printf '%s\n' "$CHINESE" | wc -l)" ] \
  || die "the English and Chinese lists differ in length"
BAD="$(printf '%s\n' "$ENGLISH" | grep -Ev '^[0-9]+\. \*\*[^*]+\*\*: .+\.$' || true)"
[ -z "$BAD" ] || die "not 'N. **Label**: sentence.': $BAD"
BAD="$(printf '%s\n' "$CHINESE" | grep -Ev '^[0-9]+\. \*\*[^*]+\*\*：.+。$' || true)"
[ -z "$BAD" ] || die "不是“N. **标签**：一句话。”的格式: $BAD"
echo "Release notes match V$VERSION ($(printf '%s\n' "$ENGLISH" | wc -l | tr -d ' ') items in each language)."
