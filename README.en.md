<div align="center">
  <img src="Documentation/Images/AppIcon.png" width="88" height="88" alt="Gallery icon">
  <h1>Gallery</h1>
  <p><b>Animated mouse cursors for your Mac.</b></p>
  <p>Windows cursor imports · Click and idle animations · Hotspot and frame editing · Visual theme library</p>
  <p><a href="README.md">简体中文</a> · <b>English</b></p>
  <p>
    <a href="https://github.com/Danningcarer/Gallery/releases/latest"><img src="https://img.shields.io/github/v/release/Danningcarer/Gallery?style=flat-square&label=release" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-555?style=flat-square" alt="macOS 14 and later">
    <img src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-Universal-555?style=flat-square" alt="Universal application for Apple Silicon and Intel">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-noncommercial-76634c?style=flat-square" alt="Noncommercial license"></a>
  </p>
  <p><a href="https://github.com/Danningcarer/Gallery/releases/latest"><b>Download</b></a> · <a href="#quick-start">Quick start</a> · <a href="https://github.com/Danningcarer/Gallery/issues/new/choose">Report an issue</a></p>
</div>

Gallery is a macOS cursor customization and editing app built on [Mousecape](https://github.com/alexzielenski/Mousecape). It brings normal and idle loops, press/hold/release animations, Windows cursor imports, and visual editing into one app. The interface supports **English and Simplified Chinese, following macOS language preferences automatically**, including the system's per-app language setting.

<a id="quick-start"></a>
## Quick start

1. **Install:** Download `Gallery-macOS.zip` from [Releases](https://github.com/Danningcarer/Gallery/releases/latest), unzip it, and move `Gallery.app` to Applications. Requires macOS 14 or later; supports Apple Silicon and Intel.
2. **Import:** Click **＋** at the top right to choose a file or folder, or drop one into the window. The complete import guide opens the first time; reopen it with **ⓘ** beside the title. For packages containing multiple sets or variants, choose what to keep and preview materials on demand.
3. **Apply:** Click a card to select it, then **▶** to start. Click the selected or active card again to edit it. Click **⏸** to stop and restore your cursors. Menu bar controls remain available after closing the window.

The built-in demo is drawn by this project and needs no external artwork. Only the active theme is locked for material editing; stop it to edit. Other themes remain editable.

## Features

| | What you can do |
| --- | --- |
| Animation | Normal and idle loops, press, hold, and release. Hold assets loop until mouse-up; each role can override its idle delay |
| Visual editing | Pick or enter hotspots; adjust dimensions and frame timing; duplicate, replace, append, move, or delete the current frame; preview animations |
| Size and appearance | Independent theme-wide and per-role size, each from 25% to 300%; optional antialiasing and soft shadows |
| Theme gallery | Static covers, custom cover frames, search, drag reordering, rename, export, and move whole themes to Trash |
| Role mixing | Use another theme's material for one role, keep a native cursor, or switch between several variants for the same role |
| Everyday controls | Launch at login, apply on launch, hide the Dock icon while active, shake to enlarge, and pause interactions in selected apps |

Roles include normal, help, link, working in background, busy, precision/text selection, move, and directional resize. Windows-only roles remain editable assets. macOS and the foreground app determine which roles are actually displayed.

## Import support

**Gallery reads assets without running Windows EXEs, DLLs, or INF commands.** Wallpapers, app icons, and unrelated programs are skipped; original files stay unchanged.

| Input | Supported content |
| --- | --- |
| `.gallery` / `.cape` | Complete Gallery themes and variants; Mousecape normal-state cursors |
| `.cur` / `.ani` | Individual static or animated cursors; ANI sequence, timing, and hotspots |
| Folder / `.inf` | CUR/ANI assets with their installation configuration; independently configured sets can be imported separately |
| `.zip` | Common compression, ZIP64, Unicode and common legacy Chinese filenames; extracts only requested content |
| `.exe` | Supported .NET resources, .NET single-file bundles, Inno Setup, and ZIP self-extractors |
| Within the editor | PNG sequences, GIF, CUR, and ANI; append frames or replace an animation |

Outer ZIP/EXE packages can be up to **2 GB**. Individual cursors are limited to 40 MB, ordinary expanded sets to 80 MB, with separate bounds on counts and image dimensions. Select variants before importing; each set becomes a separate theme. Other packers, encrypted archives, download launchers, or damaged files may need manual extraction to a CUR/ANI folder first. See [format compatibility](Documentation/COMPATIBILITY.md) for exact limits.

## Permissions, privacy, and recovery

- **Input Monitoring** enables read-only mouse event listening. Gallery does not record keys, intercept clicks, or require Accessibility permission. Without it, fallback mouse events and counters are used; responsiveness can differ across apps.
- **Themes stay on your Mac.** The app does not upload imported cursor assets or require an online theme service.
- **Back up before applying; restore when stopping.** Stop or quit normally to restore your previous cursors. After a crash or force quit, reopen Gallery and use recovery. Avoid running another automatic cursor-replacement app at the same time.
- **Compatibility has limits:** Gallery uses private macOS cursor interfaces. Some application-drawn cursors and system security screens may remain native, and macOS updates can affect compatibility.

Current releases are ad-hoc signed and **not Developer ID notarized**. macOS may require approval in Privacy & Security. Obtain the app from this repository's Releases; there is no need to disable system security protections.

## Frequently asked questions

<details>
<summary>Why is a cursor static, or why does one role not animate?</summary>

Check that the theme is active, an animated material is selected, and the corresponding animation contains frames. Single-frame materials do not have a normal loop. The foreground app chooses cursor roles; Gallery does not read page contents to infer links. App-drawn or unknown cursors may temporarily remain native. Input Monitoring can improve cross-app mouse event delivery.

</details>

<details>
<summary>Why is a theme locked, or its preview button unavailable?</summary>

Stop the active theme before editing material or playing its editor preview. Other themes remain editable. Theme and role size can be adjusted while active. Previews pause when hidden, inactive, or covered by settings to reduce resource use.

</details>

<details>
<summary>Why do appearance changes take a moment to reach thumbnails?</summary>

Changing smoothing or shadows regenerates covers and role thumbnails in the background without modifying the source artwork. An older library can take a moment to rebuild. Stop the active theme before changing its appearance, then apply it again.

</details>

<details>
<summary>How do I restore my original cursors?</summary>

Choose Stop & Restore in the toolbar or menu bar, or quit normally. After a force quit, reopen the app and use recovery. Stop any other cursor-replacement software first. Signing out and back in resets session resources if normal recovery is unavailable.

</details>

## Performance

The priority is **click response → CPU/energy → size**. macOS owns cursor position and compositing. Short normal loops use native playback; other animations reuse bounded resource caches. Static gallery cards do not refresh continuously, and material previews run only on demand.

Version 1.0.1 reduces repeated status formatting, temporary scheduling allocations, and screen-information queries. It does not increase polling, reduce frame rate, or replace the established playback/recovery path. See [performance notes](Documentation/PERFORMANCE-1.0.1.md) for measurements and their limits.

## Build and test

Requires **Xcode 26.2+ or its Command Line Tools**, targeting macOS 14. The import helper downloads and verifies pinned dependencies on its first build. The installed app has no Homebrew runtime dependency.

```sh
git clone https://github.com/Danningcarer/Gallery.git
cd Gallery
bash Scripts/check.sh
bash Scripts/localization-check.sh
GALLERY_UNIVERSAL=1 bash Scripts/build.sh
```

Outputs are `dist/Gallery.app` and `dist/Gallery-macOS.zip`; local debug symbols remain in `dist/Symbols`. Default core and language checks do not modify system cursors. System integration checks require a desktop session and a separate recovery journal and must be run explicitly.

Convert a supported Windows cursor package without opening the editor:

```sh
./dist/Gallery.app/Contents/MacOS/Gallery --convert-windows /path/to/cursors.exe /path/to/theme.gallery
```

[Report bugs or request features](https://github.com/Danningcarer/Gallery/issues/new/choose) in English or Chinese, or contribute a change. Include app/macOS versions and reproducible steps; omit private information and artwork you cannot redistribute. See [contributing](CONTRIBUTING.md), [testing](Documentation/TESTING.md), and the [1.0.1 release notes](Documentation/RELEASE-1.0.1.md).

## License and credits

Gallery retains Mousecape's **noncommercial license**. Public source availability does not make this an unrestricted open-source project; Gallery is not MIT/OSI-licensed. Follow [LICENSE](LICENSE) when using or distributing it. Fonts, import components, and other dependencies retain their individual licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

Third-party cursor artwork and Windows installers are not distributed with the project. Obtain material legally; importing it does not grant redistribution rights. Thanks to the authors of Mousecape and the included dependencies.
