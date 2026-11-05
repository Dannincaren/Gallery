#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
bin_path="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/settings-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -D GALLERY_RUNTIME_CHECKS -parse-as-library \
    -I "$bin_path/Modules" -I "$bin_path/GalleryNative.build" \
    Sources/GalleryApp/Runtime.swift Sources/GalleryApp/Store.swift Sources/GalleryApp/ThemeReadCache.swift Sources/GalleryApp/Demo.swift Sources/GalleryApp/AppPreferences.swift \
    Sources/GalleryApp/MouseObservation.swift Sources/GalleryApp/SystemCursorRenderer.swift Sources/GalleryApp/CursorRecognition.swift \
    Sources/GalleryApp/PreparedCursor.swift Sources/GalleryApp/SystemSceneMonitor.swift Tests/SettingsRuntimeHarness.swift \
    "$bin_path"/GalleryCore.build/*.swift.o "$bin_path/GalleryNative.build/CursorBridge.m.o" \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement -o .build/settings-check/GallerySettingsChecks
if [[ "${GALLERY_BUILD_ONLY:-0}" != "1" ]]; then
    .build/settings-check/GallerySettingsChecks "$1" "$2"
fi
