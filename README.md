# Gallery — animated cursors for macOS

**Custom mouse pointers with idle, press, hold and release animations. Import Windows CUR/ANI cursor themes, edit hotspots and sizes, and use them across your Mac.**

[Download the latest release](https://github.com/Danningcarer/Gallery/releases/latest) · [中文说明](README.zh-CN.md) · [Report a bug](https://github.com/Danningcarer/Gallery/issues/new)

macOS 14 or later · Apple Silicon and Intel · SwiftUI · Source available for noncommercial use

## Start in three steps

1. Download `Gallery-macOS.zip` from **Releases**, unzip it and move **Gallery.app** to **Applications**.
2. Open Gallery and choose **+**. Import a `.gallery` or `.cape` theme, a CUR/ANI file, an INF file, a cursor folder, ZIP, or a supported Windows installer. Packages containing multiple sets or variants open a selection and preview screen.
3. Click a theme card to select it, then click **▶** to apply it. Click the selected or active card to edit its cursor roles. **⏸** restores the original cursors; the menu bar remains available when the window is closed.

The interface currently uses Simplified Chinese. **导入** means Import, **使用** means Apply, and **停用并恢复** means Stop and Restore. A built-in, original demo lets you try the app without downloading artwork.

## What it does

- **Animated macOS cursors:** normal and idle loops, immediate press, held-button and release states. A hold asset automatically enables hold-until-release behavior.
- **Cursor editor:** frame preview, duplicate/reorder frames, replace images, edit the hotspot, adjust animation timing, and pick a frame as the theme cover.
- **Independent sizing:** per-theme overall size and per-role size (25–300% each), with sliders and numeric input. Unrecognized application-owned cursors keep their original size.
- **Theme library:** static cover cards, search, drag-to-reorder, clear active/selected states, per-theme export and deletion, and mixing a role from another theme or using a native cursor.
- **Appearance:** optional smoothing and baked shadows. Covers and role thumbnails regenerate when appearance changes; cards do not continuously animate.
- **Desktop integration:** optional launch at login, apply at launch, hide the Dock icon, shake-to-enlarge, and per-application interaction exclusions.

## Import compatibility

| Input | Supported content |
| --- | --- |
| `.gallery` | Full Gallery themes, variants and interaction settings |
| `.cape` | Mousecape normal-state cursors and animations |
| `.cur` / `.ani` | A standalone cursor, or files inside a folder/ZIP; source timing and hotspots are preserved |
| `.inf` | Windows cursor-role declarations; referenced CUR/ANI files must accompany the INF |
| Folder / `.zip` | Cursor sets with or without INF; independent configured subfolders can be imported separately |
| `.exe` | Embedded managed resources in supported .NET installers, .NET single-file bundles, Inno Setup, and ZIP self-extractors |

**Windows executables are read as data and never run.** Gallery keeps cursor material and necessary configuration, skipping wallpaper, application icons and unrelated programs. Installers are not a universal format: encrypted archives, missing companion data and other custom packers may require extracting the CUR/ANI files first.

ZIP handling supports stored/Deflate entries, ZIP64, common Unicode and legacy Chinese filenames, and integrity checks. Other compression methods use the system extractor when available. ZIP/EXE inputs may be up to **2 GB**; extracted cursor data, counts and image dimensions have separate limits. See [compatibility and limits](Documentation/COMPATIBILITY.md).

## Permissions and recovery

Input Monitoring enables the mouse-only session listener for more reliable input delivery. Gallery does not record keyboard input or ask for Accessibility permission. A fallback mouse-event/counter path is used when session listening is unavailable; responsiveness can vary between applications.

Gallery backs up cursor resources before applying a theme. Stop or quit normally to restore them. After a crash or force quit, reopen Gallery and use the recovery action. Avoid running another cursor-replacement app at the same time.

Gallery uses private macOS cursor interfaces. Some custom application cursors and system security screens may remain native; compatibility can change with macOS updates. Releases are currently ad-hoc signed and **not Developer ID notarized**. See [troubleshooting](Documentation/TROUBLESHOOTING.md).

## Performance

The cursor position and compositing stay with macOS. Short normal animations use native playback; longer animations and interactions reuse bounded prepared-frame caches. Static cards and thumbnails stay still, and previews stop when hidden. Performance work prioritizes click response, then CPU/energy, then package size.

[Performance measurements](Documentation/PERFORMANCE-1.0.0.md) distinguish processing time from hardware-to-display latency. No increased polling frequency or reduced animation frame rate is used to claim an improvement.

## Build and test

Build with **Xcode 26.2+ or its Command Line Tools**, targeting macOS 14+. Both architectures are included by the release script. The separate import helper uses pinned, verified dependencies downloaded on the first build; the app has no Homebrew runtime dependency.

```sh
bash Scripts/check.sh
GALLERY_UNIVERSAL=1 bash Scripts/build.sh
```

The result is `dist/Gallery.app` and `dist/Gallery-macOS.zip`. Local debug symbols are kept in `dist/Symbols`. Core checks use synthetic assets and do not modify the system cursor. System cursor checks are opt-in and should run after stopping any existing cursor replacement.

To convert a supported Windows cursor package without opening the editor:

```sh
Gallery.app/Contents/MacOS/Gallery --convert-windows /path/to/cursors.exe /path/to/theme.gallery
```

See [testing](Documentation/TESTING.md) and the [1.0.0 release notes](Documentation/RELEASE-1.0.0.md).

## License and artwork

Gallery extends [Mousecape](https://github.com/alexzielenski/Mousecape) and retains its **noncommercial license**. This is source-available software, not an MIT-licensed or unrestricted open-source project. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).

Third-party cursor artwork and Windows installers are not included. Import your own legally obtained material; importing does not grant permission to redistribute it.
