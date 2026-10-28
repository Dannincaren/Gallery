#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Gallery
bin_path="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p .build/live-check
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -D GALLERY_RUNTIME_CHECKS -parse-as-library -I "$bin_path/Modules" -I "$bin_path/GalleryNative.build" \
    Sources/GalleryApp/Runtime.swift Sources/GalleryApp/MouseObservation.swift Sources/GalleryApp/SystemCursorRenderer.swift \
    Sources/GalleryApp/CursorRecognition.swift Sources/GalleryApp/PreparedCursor.swift Sources/GalleryApp/SystemSceneMonitor.swift Tests/LiveInputHarness.swift \
    "$bin_path"/GalleryCore.build/*.swift.o "$bin_path/GalleryNative.build/CursorBridge.m.o" \
    -framework AppKit -framework ApplicationServices -o .build/live-check/LiveInputChecks
python3 - "$1" "$2" "${3:-}" <<'PY'
import pathlib,sys,plistlib,json,shutil
root=pathlib.Path(sys.argv[1]).resolve();root.mkdir(parents=True,exist_ok=True)
config=dict(directory=str(root),theme=str(pathlib.Path(sys.argv[2]).resolve()))
if sys.argv[3]=='--trace-only': config.update(traceOnly='1',scale='1.86')
for name,suffix in [('Gallery Input Probe','Probe'),('Gallery Test Surface','Fixture')]:
 app=root/(name+'.app');(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True);(app/'Contents/Resources').mkdir(exist_ok=True)
 shutil.copy2('.build/live-check/LiveInputChecks',app/'Contents/MacOS/LiveInputChecks')
 plistlib.dump(dict(CFBundleIdentifier='io.github.rp0902.Gallery.Test'+suffix,CFBundleName=name,CFBundleExecutable='LiveInputChecks',CFBundlePackageType='APPL',LSMinimumSystemVersion='14.0',LSUIElement=suffix=='Probe'),(app/'Contents/Info.plist').open('wb'))
 (app/'Contents/Resources/config.json').write_text(json.dumps(config))
 print(app)
PY
