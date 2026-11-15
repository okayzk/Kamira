#!/bin/bash
# Unit tests for everything that has no window: image handling, annotation geometry,
# GIF writing, scroll stitching, text recognition, window shadows, shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
/usr/bin/xcrun swiftc -swift-version 5 -framework AppKit -framework Carbon \
  Sources/App/Localization.swift Sources/App/Shortcut.swift Sources/App/FileNaming.swift \
  Sources/Capture/CapturedImage.swift Sources/Capture/ScrollStitcher.swift \
  Sources/Capture/ScrollPreview.swift \
  Sources/Capture/TextRecognizer.swift Sources/Capture/WindowShadow.swift \
  Sources/Editor/Annotation.swift Sources/Recording/GIFWriter.swift \
  Tests/main.swift -o build/tests
build/tests
