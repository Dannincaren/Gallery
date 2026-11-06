#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
gallery_bin="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/update-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    -I "$gallery_bin/Modules" Tests/UpdateHarness.swift Sources/GalleryApp/AppUpdateChecker.swift "$gallery_bin"/GalleryCore.build/*.swift.o \
    -o .build/update-check/GalleryUpdateChecks
.build/update-check/GalleryUpdateChecks "$@"
