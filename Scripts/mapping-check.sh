#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --target GalleryCore
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --target GalleryNative
gallery_bin="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/mapping-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    -I "$gallery_bin/Modules" -I "$gallery_bin/GalleryNative.build" \
    Sources/GalleryApp/Store.swift Sources/GalleryApp/ThemeReadCache.swift Sources/GalleryApp/Demo.swift Sources/GalleryApp/AppPreferences.swift \
    Sources/GalleryApp/ThemeMappingDraft.swift Sources/GalleryApp/MappingArtwork.swift Sources/GalleryApp/MappingViewportReader.swift Sources/GalleryApp/MappingBoardInput.swift Sources/GalleryApp/RuntimeStatus.swift Tests/StartupRuntime.swift Tests/MappingHarness.swift \
    "$gallery_bin"/GalleryCore.build/*.swift.o "$gallery_bin/GalleryNative.build"/*.o \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement -o .build/mapping-check/GalleryMappingChecks
.build/mapping-check/GalleryMappingChecks
