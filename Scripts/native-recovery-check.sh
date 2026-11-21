#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release)
swift build "${args[@]}" --target GalleryCore
bin_path="$(swift build "${args[@]}" --show-bin-path)"
mkdir -p .build/recovery-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -parse-as-library -I "$bin_path/Modules" \
    Tests/NativeRecoveryHarness.swift "$bin_path"/GalleryCore.build/*.swift.o -framework AppKit -o .build/recovery-check/GalleryRecoveryChecks
.build/recovery-check/GalleryRecoveryChecks "$@"
