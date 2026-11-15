#!/bin/bash
# Redraws Resources/AppIcon.icns and assets/logo.png from the mark in
# Sources/App/AppMark.swift, the same drawing the menu bar icon uses.
#
#   scripts/make_icon.sh           redraw both files (`make icon`)
#   scripts/make_icon.sh --check   redraw into a scratch folder and compare, changing
#                                  nothing: fails when AppMark.swift was edited and
#                                  `make icon` was not run (the release preflight)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-draw}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
/usr/bin/xcrun swiftc -O -parse-as-library scripts/make_icon.swift Sources/App/AppMark.swift \
  -o "$SCRATCH/make_icon"
SET="$SCRATCH/AppIcon.iconset"
mkdir -p "$SET"
for points in 16 32 128 256 512; do
  "$SCRATCH/make_icon" "$points" "$SET/icon_${points}x${points}.png"
  "$SCRATCH/make_icon" "$((points * 2))" "$SET/icon_${points}x${points}@2x.png"
done
"$SCRATCH/make_icon" 512 "$SCRATCH/logo.png"

if [ "$MODE" = --check ]; then
  /usr/bin/iconutil -c iconset Resources/AppIcon.icns -o "$SCRATCH/committed.iconset"
  PAIRS=("assets/logo.png" "$SCRATCH/logo.png")
  # iconutil keeps 16 × 16 and 32 × 32 at 1x in the old lossy format, edges off by up to
  # 212 after a round trip. Their @2x twins are exact, and any change to the drawing shows
  # in every larger size, so those two are left out.
  for drawn in "$SET"/*.png; do
    case "$(basename "$drawn")" in icon_16x16.png|icon_32x32.png) continue ;; esac
    PAIRS+=("$SCRATCH/committed.iconset/$(basename "$drawn")" "$drawn")
  done
  # Pixels, not bytes: PNG encoders differ, and a rounding step may move a channel by one.
  python3 - "${PAIRS[@]}" <<'EOF'
import subprocess, sys, tempfile, os
def pixels(path, folder):
    out = os.path.join(folder, f"{len(os.listdir(folder))}.bmp")
    subprocess.run(["sips", "-s", "format", "bmp", path, "--out", out], capture_output=True, check=True)
    data = open(out, "rb").read()
    return data[int.from_bytes(data[10:14], "little"):], data[18:26]
stale = []
with tempfile.TemporaryDirectory() as folder:
    paths = sys.argv[1:]
    for committed, drawn in zip(paths[::2], paths[1::2]):
        if not os.path.exists(committed):
            stale.append(f"{os.path.basename(committed)}: missing")
            continue
        (a, size_a), (b, size_b) = pixels(committed, folder), pixels(drawn, folder)
        if size_a != size_b or max((abs(x - y) for x, y in zip(a, b)), default=0) > 2:
            stale.append(os.path.basename(committed))
if stale:
    print("The icon files do not match Sources/App/AppMark.swift; run `make icon`: " + ", ".join(stale))
    sys.exit(1)
print("Icon files match Sources/App/AppMark.swift.")
EOF
  exit
fi

mkdir -p assets
/usr/bin/iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SCRATCH/logo.png" assets/logo.png
echo "Wrote Resources/AppIcon.icns and assets/logo.png"
