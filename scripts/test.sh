#!/bin/bash
# Unit tests for everything that has no window: image handling, annotation geometry,
# GIF writing, scroll stitching, text recognition, window shadows, shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
/usr/bin/xcrun swiftc -swift-version 5 -framework AppKit -framework Carbon \
  Sources/Shared/Localization.swift Sources/Shared/Shortcut.swift Sources/Shared/SystemHotKey.swift Sources/Shared/ShortcutAction.swift Sources/Shared/FileNaming.swift Sources/Shared/RecordingSize.swift Sources/Shared/PreviewTiming.swift Sources/Shared/UpdatePolicy.swift Sources/Shared/CapturedImage.swift \
  Sources/Recording/LogFile.swift Sources/Recording/GIFWriter.swift \
  Sources/ScrollCapture/ScrollStitcher.swift Sources/ScrollCapture/ScrollPreviewStrip.swift Sources/ScrollCapture/ScrollPreviewLayout.swift \
  Sources/TextRecognition/TextRecognizer.swift \
  Sources/Screenshot/WindowShadow.swift \
  Sources/Editor/Annotation.swift Sources/Editor/AnnotationTool.swift Sources/Editor/AnnotationRenderer.swift Sources/Editor/EditorZoom.swift \
  Tests/main.swift -o build/tests
build/tests
