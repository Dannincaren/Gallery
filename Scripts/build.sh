#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_mode="${1:-release}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
build_args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c "$build_mode" --product Gallery)
if [[ "${GALLERY_UNIVERSAL:-0}" == "1" ]]; then
    # Separate SwiftPM builds also work with Command Line Tools, where the
    # multi-arch build driver requires a full Xcode installation.
    gallery_slices=()
    for gallery_arch in arm64 x86_64; do
        gallery_arch_args=("${build_args[@]}" --scratch-path ".build/universal-$gallery_arch" --triple "$gallery_arch-apple-macosx14.0")
        swift build "${gallery_arch_args[@]}"
        gallery_arch_dir="$(swift build "${gallery_arch_args[@]}" --show-bin-path)"
        gallery_slices+=("$gallery_arch_dir/Gallery")
    done
    binary_dir="$PWD/.build/universal-product"
    mkdir -p "$binary_dir"
    lipo -create "${gallery_slices[@]}" -output "$binary_dir/Gallery"
else
    swift build "${build_args[@]}"
    binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
fi
bash Scripts/build-inno-helper.sh
output_dir="${GALLERY_OUTPUT_DIR:-$PWD/dist}"
app_dir="$output_dir/Gallery.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp "$binary_dir/Gallery" "$app_dir/Contents/MacOS/Gallery"
cp -R Resources/*.lproj "$app_dir/Contents/Resources/"
cp Resources/NativeCursorPreviews.plist Resources/NativeCursorPreviews.md "$app_dir/Contents/Resources/"
for gallery_table in "$app_dir"/Contents/Resources/*.lproj/*.strings; do
    plutil -convert binary1 "$gallery_table"
done
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "${GALLERY_LOCAL_VERSION:-}" ]]; then
    python3 - "$app_dir/Contents/Info.plist" "$GALLERY_LOCAL_VERSION" "${GALLERY_LOCAL_BUILD:-35}" <<'PY'
from pathlib import Path
import plistlib,re,sys
path=Path(sys.argv[1]); version=sys.argv[2]; build=sys.argv[3]
assert re.fullmatch(r'\d+\.\d+\.\d+\.\d+', version), 'Local versions need four numeric components'
assert build.isdigit()
info=plistlib.loads(path.read_bytes())
info.update(CFBundleShortVersionString=version,CFBundleVersion=build)
path.write_bytes(plistlib.dumps(info))
PY
fi
cp LICENSE THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
cp .build/GalleryInno "$app_dir/Contents/Helpers/GalleryInno"
if [[ "$build_mode" == "release" ]]; then
    # Keep symbols locally for diagnostics; only strip the distributable copies.
    mkdir -p "$output_dir/Symbols"
    dsymutil "$app_dir/Contents/MacOS/Gallery" -o "$output_dir/Symbols/Gallery.app.dSYM"
    strip -S -x "$app_dir/Contents/MacOS/Gallery" "$app_dir/Contents/Helpers/GalleryInno"
fi
cp -R Resources/ThirdParty "$app_dir/Contents/Resources/"
mkdir -p "$app_dir/Contents/Resources/Fonts"
cp Resources/Fonts/* "$app_dir/Contents/Resources/Fonts/"
# Keep the reviewed icon identical across build hosts and macOS symbol versions.
# Regeneration remains a separate development task in Scripts/make-icon.swift.
cp Resources/Gallery.icns "$app_dir/Contents/Resources/Gallery.icns"
plutil -lint "$app_dir/Contents/Info.plist"
if [[ -n "${GALLERY_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$GALLERY_SIGN_IDENTITY" "$app_dir/Contents/Helpers/GalleryInno"
    codesign --force --options runtime --timestamp --sign "$GALLERY_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir/Contents/Helpers/GalleryInno"
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9 "$app_dir" "$output_dir/Gallery-macOS.zip"
printf 'Built: %s\n' "$app_dir"
