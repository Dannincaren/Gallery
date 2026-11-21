#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
gallery_args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release)
swift build "${gallery_args[@]}" --target GalleryCore
swift build "${gallery_args[@]}" --target GalleryNative
gallery_bin="$(swift build "${gallery_args[@]}" --show-bin-path)"
mkdir -p .build/native-loop-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -D GALLERY_RUNTIME_CHECKS -parse-as-library \
    -I "$gallery_bin/Modules" -I "$gallery_bin/GalleryNative.build" \
    Sources/GalleryApp/PreparedCursor.swift Sources/GalleryApp/SystemCursorRenderer.swift Sources/GalleryApp/CursorRecognition.swift Tests/NativeLoopHarness.swift \
    "$gallery_bin"/GalleryCore.build/*.swift.o "$gallery_bin"/GalleryNative.build/*.o \
    -framework AppKit -framework ApplicationServices -o .build/native-loop-check/GalleryNativeLoopChecks
if [[ "${GALLERY_BUILD_ONLY:-0}" != "1" ]]; then
    .build/native-loop-check/GalleryNativeLoopChecks
fi
