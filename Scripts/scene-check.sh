#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
gallery_args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release)
swift build "${gallery_args[@]}" --target GalleryNative
gallery_bin="$(swift build "${gallery_args[@]}" --show-bin-path)"
mkdir -p .build/scene-check
clang -fobjc-arc -O2 -I Sources/GalleryNative/include Tests/SceneHarness.m \
    "$gallery_bin/GalleryNative.build/CursorBridge.m.o" \
    -framework AppKit -framework ApplicationServices -o .build/scene-check/GallerySceneChecks
if [[ "${GALLERY_BUILD_ONLY:-0}" != "1" ]]; then
    .build/scene-check/GallerySceneChecks
fi
