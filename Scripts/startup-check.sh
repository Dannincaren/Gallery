#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
gallery_bin="$(swift build --disable-sandbox -c release --show-bin-path)"
gallery_check="$PWD/.build/startup-check/Gallery Startup Checks.app/Contents"
gallery_root="${1:?Supply an isolated output directory}"
mkdir -p "$gallery_check/MacOS" "$gallery_check/Resources"
cp Resources/Info.plist "$gallery_check/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.gallery.startup-check' "$gallery_check/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Gallery Startup Checks' "$gallery_check/Info.plist"
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    -I "$gallery_bin/Modules" Sources/GalleryApp/AppDelegate.swift Sources/GalleryApp/Store.swift \
    Sources/GalleryApp/ThemeReadCache.swift Sources/GalleryApp/Demo.swift Sources/GalleryApp/AppPreferences.swift \
    Sources/GalleryApp/RuntimeStatus.swift Tests/StartupRuntime.swift Tests/StartupHarness.swift "$gallery_bin"/GalleryCore.build/*.swift.o \
    -framework AppKit -framework ServiceManagement -o "$gallery_check/MacOS/Gallery"
codesign --force --sign - "$gallery_check/.."
for gallery_scenario in normal late-binding no-auto keep-dock missing-last recovery pending-document; do
    "$gallery_check/MacOS/Gallery" "$gallery_scenario" "$gallery_root/$gallery_scenario"
done
