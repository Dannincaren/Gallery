# Testing Gallery

## Core checks

```sh
bash Scripts/check.sh
```

The default suite uses synthetic assets, requires no third-party downloads and does not change system cursors. It covers interaction timing, fast input edges, press/hold/release rules, role families, archive migration, independent theme/role sizes (25–300%), appearance and preview-cache invalidation, frame editing, CUR/ANI decoding, INF mapping, and bounded imports.

Import fixtures include PE32/PE32+ managed resources; uncompressed and compressed .NET single-file manifest versions 1/2/6; duplicate ReadyToRun assets; standalone CUR/ANI; folder/INF/ZIP equivalence; UTF-16 INF; Unicode and legacy Chinese ZIP names; ZIP64; streaming Deflate; ZIP self-extractors; CRC corruption; invalid paths, offsets and declared lengths. Inno grouping/filtering uses synthetic directories; the bundled helper is checked separately.

Optional integration tests use local files, never downloaded or uploaded by the suite:

- `GALLERY_RESOURCE_EXE`: an installer matching the resource-rich reference schema.
- `GALLERY_WINDOWS_EXE` and optional `GALLERY_WINDOWS_ZIP`: the compact reference cursor installer and equivalent archive.
- `GALLERY_CURSOR_DIRECTORY`: the reference 13-ANI folder.

These tests expect the reference fixture structure; they are not generic validation commands for arbitrary artwork. Legacy environment variable aliases remain accepted. Fixtures are intentionally absent from the repository.

## Editor checks

```sh
bash Scripts/editor-check.sh /tmp/gallery-editor-check
```

Use a fresh directory. This verifies isolated libraries, per-theme sizes, 25% bounds, drag ordering, pending saves, material variants, mixed/native roles, role aliases, covers, rename and whole-theme deletion. It does not enable cursors, change login items or modify the normal user library.

## System cursor checks

Stop and quit any running cursor replacement first. These checks temporarily replace system resources and keep an independent recovery journal in the supplied directory. Run them sequentially, with a compatible `.gallery` fixture:

```sh
bash Scripts/runtime-check.sh /tmp/gallery-runtime-check /path/to/theme.gallery
bash Scripts/settings-check.sh /tmp/gallery-settings-check /path/to/theme.gallery
```

The settings fixture must include the expected 32-point geometry, animated roles and an alternate static text variant. Checks cover visible frame progression, press/hold/release continuity, stale observation rejection, resizing, appearance, active-theme edit isolation and restoration. They do not move the pointer or post OS input events. A passing controlled check does not prove every foreground application behaves correctly.

## Desktop review before release

Review arrows, text and links while stationary and moving in native and third-party apps. Test rapid clicks, held drags and release, idle, resize dividers, Dock, Mission Control, Spaces/full screen, custom application cursors, shake-to-enlarge, changing size, import previews, stop/quit and recovery. The application supplies the native role; Gallery does not inspect page contents to infer links. Some applications intentionally choose an arrow in editable text.

Performance measurements must preserve theme, scale, frame rate and observation mode. Report CPU separately from WindowServer and from energy use. A callback or resource-preparation timing is not physical input-to-display latency. See [1.0 measurements](PERFORMANCE-1.0.0.md).

## Release package

```sh
GALLERY_UNIVERSAL=1 bash Scripts/build.sh
```

Verify both Mach-O architectures, signatures after unzip, embedded helper launch, version, dependency paths, required fonts/licenses and archive integrity. Search the final shipped binaries and documentation for local user paths and private fixture names. Keep debug symbols, credentials, recovery journals and third-party artwork outside the published archive.

Releases are ad-hoc signed unless a Developer ID identity is supplied. This does not imply notarization. A push to `main` builds and checks an artifact; it does not automatically publish a release.
