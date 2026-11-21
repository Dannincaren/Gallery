#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
gallery_deps="${GALLERY_INNO_DEPS:-$PWD/.build/inno-deps}"
mkdir -p .build/lzma-check
clang++ -O2 -std=c++11 -mmacosx-version-min=14.0 \
    -I Vendor/Innoextract/src -I ".build/inno-$(uname -m)" \
    -I "$gallery_deps/boost_1_85_0" -I "$gallery_deps/xz-5.8.4/src/liblzma/api" \
    Tests/LZMAHarness.cpp Vendor/Innoextract/src/stream/lzma.cpp Vendor/Innoextract/src/util/load.cpp \
    -Wl,-dead_strip \
    "$gallery_deps/lzma-5.8.4-build/liblzma.a" -o .build/lzma-check/GalleryLZMAChecks
.build/lzma-check/GalleryLZMAChecks
