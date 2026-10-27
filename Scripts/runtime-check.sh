#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
bin_path="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/runtime-check
swiftc -O -swift-version 5 -D GALLERY_RUNTIME_CHECKS -parse-as-library \
    -I "$bin_path/Modules" -I "$bin_path/GalleryNative.build" \
    Sources/GalleryApp/Runtime.swift Sources/GalleryApp/MouseObservation.swift Sources/GalleryApp/CursorOverlay.swift Sources/GalleryApp/CursorRecognition.swift Sources/GalleryApp/PreparedCursor.swift Tests/RuntimeHarness.swift \
    "$bin_path"/GalleryCore.build/*.swift.o "$bin_path/GalleryNative.build/CursorBridge.m.o" \
    -framework AppKit -framework ApplicationServices -o .build/runtime-check/GalleryRuntimeChecks
.build/runtime-check/GalleryRuntimeChecks "$1" "$2"
