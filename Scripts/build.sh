#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_mode="${1:-release}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
build_args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c "$build_mode" --product Gallery)
if [[ "${GALLERY_UNIVERSAL:-0}" == "1" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$PWD/dist/Gallery.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Gallery" "$app_dir/Contents/MacOS/Gallery"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
swift Scripts/make-icon.swift .build/Gallery.iconset
iconutil -c icns .build/Gallery.iconset -o "$app_dir/Contents/Resources/Gallery.icns"
plutil -lint "$app_dir/Contents/Info.plist"
if [[ -n "${GALLERY_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$GALLERY_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/dist/Gallery-macOS.zip"
printf 'Built: %s\n' "$app_dir"
