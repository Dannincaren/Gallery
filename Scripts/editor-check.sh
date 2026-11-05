#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
bin_path="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/editor-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I "$bin_path/Modules" -I "$bin_path/GalleryNative.build" \
    Sources/GalleryApp/Store.swift Sources/GalleryApp/ThemeReadCache.swift Sources/GalleryApp/Demo.swift Sources/GalleryApp/AppPreferences.swift \
    Sources/GalleryApp/Runtime.swift Sources/GalleryApp/MouseObservation.swift Sources/GalleryApp/SystemCursorRenderer.swift \
    Sources/GalleryApp/CursorRecognition.swift Sources/GalleryApp/PreparedCursor.swift Sources/GalleryApp/SystemSceneMonitor.swift Tests/EditorHarness.swift \
    "$bin_path"/GalleryCore.build/*.swift.o "$bin_path/GalleryNative.build/CursorBridge.m.o" \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement -o .build/editor-check/GalleryEditorChecks
.build/editor-check/GalleryEditorChecks "$1"
