#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
gallery_bin="$(swift build --disable-sandbox -c release --show-bin-path)"
gallery_check="$PWD/.build/localization-check/Gallery Language Checks.app/Contents"
mkdir -p "$gallery_check/MacOS" "$gallery_check/Resources"
cp Resources/Info.plist "$gallery_check/Info.plist"
cp -R Resources/*.lproj "$gallery_check/Resources/"
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    -I "$gallery_bin/Modules" Tests/LocalizationHarness.swift "$gallery_bin"/GalleryCore.build/*.swift.o \
    -o "$gallery_check/MacOS/Gallery"
"$gallery_check/MacOS/Gallery" en -AppleLanguages '(en)'
"$gallery_check/MacOS/Gallery" zh-Hans -AppleLanguages '(zh-Hans)'
"$gallery_check/MacOS/Gallery" en -AppleLanguages '(fr)'
