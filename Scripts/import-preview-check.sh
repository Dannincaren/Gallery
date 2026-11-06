#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
gallery_bin="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/import-preview-check
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    -I "$gallery_bin/Modules" Tests/ImportPreviewHarness.swift Sources/GalleryApp/ImportMaterialPreview.swift "$gallery_bin"/GalleryCore.build/*.swift.o \
    -framework AppKit -o .build/import-preview-check/GalleryImportPreviewChecks
.build/import-preview-check/GalleryImportPreviewChecks
