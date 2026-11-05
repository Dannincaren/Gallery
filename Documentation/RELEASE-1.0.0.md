# Gallery 1.0.0

Animated mouse cursors for macOS 14+, for Apple Silicon and Intel. Gallery extends Mousecape with normal/idle and press/hold/release animation, an in-app hotspot/frame editor and a visual theme library.

- Reduce repeated cursor-recognition work while preserving the established animation path and input frequency.
- Import supported Windows EXE packages, including compressed/uncompressed .NET single-file bundles, Inno Setup and ZIP self-extractors. Never runs the Windows installer.
- Improve ZIP64, Unicode/legacy Chinese ZIP names, folder/INF and standalone CUR/ANI imports. Choose material sets/variants and preview only when requested; unrelated package content is discarded.
- Regenerate theme covers and role thumbnails after smoothing/shadow changes.
- Set overall and per-role size independently for each theme, now from **25% to 300%**.
- Include the theme gallery, drag ordering, custom covers, per-theme deletion, role mixing/native roles, numeric controls, optional shadows/smoothing, login launch, Dock hiding and shake-to-enlarge.
- Add general import guidance, English/Chinese documentation and compatibility/troubleshooting notes.

Download `Gallery-macOS.zip`, unzip and move Gallery.app to Applications. The interface currently uses Simplified Chinese. The built-in original demo needs no external artwork.

The app uses private macOS cursor interfaces. System security screens and some app-owned cursors may remain native; compatibility may change after OS updates. Input Monitoring improves mouse input delivery; Accessibility permission is not required. Releases are ad-hoc signed and are not Developer ID notarized.

Source is available under the retained **noncommercial Mousecape license**; this is not an unrestricted MIT/OSI open-source release. Third-party cursor themes and installers are not included.

See [compatibility](COMPATIBILITY.md), [testing](TESTING.md), [performance measurements](PERFORMANCE-1.0.0.md) and [third-party notices](../THIRD_PARTY_NOTICES.md).

Package: **2.36 MB ZIP**, **5.49 MB installed contents** (decimal units). Both architectures are included. New import support slightly increases the app compared with 0.7.9; level-9 compression changes no extracted file contents.
