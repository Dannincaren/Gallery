#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
gallery_repo="$PWD"
gallery_deps="${GALLERY_INNO_DEPS:-$PWD/.build/inno-deps}"
mkdir -p "$gallery_deps"
gallery_deps="$(cd "$gallery_deps" && pwd)"
gallery_jobs="${GALLERY_BUILD_JOBS:-4}"
fetch() {
    local target="$gallery_deps/$1" source="$2" expected="$3"
    if [[ ! -f "$target" ]]; then
        curl -fL --retry 2 "$source" -o "$target.part"
        mv "$target.part" "$target"
    fi
    local actual
    actual="$(shasum -a 256 "$target" | cut -d ' ' -f 1)"
    [[ "$actual" == "$expected" ]] || { echo "Dependency checksum failed: $target" >&2; exit 1; }
}
fetch boost_1_85_0.tar.bz2 https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2 7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617
fetch xz-5.8.1.tar.xz https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.xz 0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e
[[ -d "$gallery_deps/boost_1_85_0" ]] || tar -xjf "$gallery_deps/boost_1_85_0.tar.bz2" -C "$gallery_deps"
[[ -d "$gallery_deps/xz-5.8.1" ]] || tar -xJf "$gallery_deps/xz-5.8.1.tar.xz" -C "$gallery_deps"
gallery_cmake="${GALLERY_CMAKE:-}"
if [[ -z "$gallery_cmake" ]]; then
    # Upstream innoextract still requires policies removed by CMake 4. Use
    # the same pinned tool locally and in CI unless explicitly overridden.
    if [[ ! -x "$gallery_deps/buildtools/cmake/data/bin/cmake" ]]; then
        python3 -m pip install --disable-pip-version-check --target "$gallery_deps/buildtools" 'cmake==3.31.10'
    fi
    gallery_cmake="$gallery_deps/buildtools/cmake/data/bin/cmake"
fi
"$gallery_cmake" -S "$gallery_deps/xz-5.8.1" -B "$gallery_deps/lzma-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DBUILD_TESTING=OFF -DENABLE_NLS=OFF
"$gallery_cmake" --build "$gallery_deps/lzma-build" -j "$gallery_jobs"
if [[ ! -x "$gallery_deps/boost_1_85_0/b2" ]]; then
    (cd "$gallery_deps/boost_1_85_0"; ./bootstrap.sh --with-libraries=filesystem,program_options,iostreams,date_time,system)
fi
for gallery_arch in arm64 x86_64; do
    gallery_boost_arch=arm
    [[ "$gallery_arch" == arm64 ]] || gallery_boost_arch=x86
    if [[ ! -f "$gallery_deps/boost_1_85_0/stage-$gallery_arch/lib/libboost_program_options.a" ]]; then
        (cd "$gallery_deps/boost_1_85_0"; ./b2 -j"$gallery_jobs" link=static variant=release threading=multi \
            architecture="$gallery_boost_arch" address-model=64 \
            cxxflags="-arch $gallery_arch -mmacosx-version-min=14.0" linkflags="-arch $gallery_arch -mmacosx-version-min=14.0" \
            --stagedir="stage-$gallery_arch" stage)
    fi
    "$gallery_cmake" -S "$gallery_repo/Vendor/Innoextract" -B "$gallery_repo/.build/inno-$gallery_arch" \
        -DCMAKE_POLICY_DEFAULT_CMP0167=OLD -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$gallery_arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DBoost_NO_BOOST_CMAKE=ON -DBOOST_ROOT="$gallery_deps/boost_1_85_0" \
        -DBOOST_LIBRARYDIR="$gallery_deps/boost_1_85_0/stage-$gallery_arch/lib" -DBoost_USE_STATIC_LIBS=ON \
        -DLZMA_USE_STATIC_LIBS=ON -DLZMA_INCLUDE_DIR="$gallery_deps/xz-5.8.1/src/liblzma/api" \
        -DLZMA_LIBRARY="$gallery_deps/lzma-build/liblzma.a" -DBUILD_DECRYPTION=OFF
    "$gallery_cmake" --build "$gallery_repo/.build/inno-$gallery_arch" -j "$gallery_jobs"
done
lipo -create .build/inno-arm64/innoextract .build/inno-x86_64/innoextract -output .build/GalleryInno
codesign --force --sign - .build/GalleryInno
codesign --verify --strict --all-architectures .build/GalleryInno
