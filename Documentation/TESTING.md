# Testing Gallery

## Core checks

```sh
bash Scripts/check.sh
```

The default suite uses synthetic assets, requires no third-party downloads and does not change system cursors. It covers interaction timing, fast input edges, press/hold/release rules, role families, archive migration, independent theme/role sizes (25–300%), appearance and preview-cache invalidation, frame editing, CUR/ANI decoding, INF mapping, and bounded imports.

Click-isolation checks cover all cursor-family pairs in split and unsplit modes: a new role cannot inherit press deadlines or mouse-up animations, while returning to the original role preserves its own timeline. They also cover unknown roles, pause/reset, independent release durations, held-button idle suppression and alias continuity. Inactive roles do not create timers.

Import fixtures include PE32/PE32+ managed resources; uncompressed and compressed .NET single-file manifest versions 1/2/6; duplicate ReadyToRun assets; standalone CUR/ANI; folder/INF/ZIP equivalence; UTF-16 INF; Unicode and legacy Chinese ZIP names; ZIP64; streaming Deflate; ZIP self-extractors; CRC corruption; invalid paths, offsets and declared lengths. Security fixtures also reject symlinks/FIFOs/oversized files, non-finite geometry and malformed identifiers, cumulative decoded-image budgets, excessive cape representations and mismatched CUR dimensions. Long ANI fixtures verify bounded pre-decode sampling and original cycle timing. Inno grouping/filtering uses synthetic directories; the bundled helper is checked separately.

Optional integration tests use local files, never downloaded or uploaded by the suite:

- `GALLERY_RESOURCE_EXE`: an installer matching the resource-rich reference schema.
- `GALLERY_WINDOWS_EXE` and optional `GALLERY_WINDOWS_ZIP`: the compact reference cursor installer and equivalent archive.
- `GALLERY_CURSOR_DIRECTORY`: the reference 13-ANI folder.

These tests expect the reference fixture structure; they are not generic validation commands for arbitrary artwork. Legacy environment variable aliases remain accepted. Fixtures are intentionally absent from the repository.

## System scene checks

```sh
bash Scripts/scene-check.sh
```

This registers a read-only observer and injects callbacks only into its own
implementation. It checks Mission Control entry/exit, Space-completion delivery,
ignored Space-start guesses, single ownership, restart, idempotent cleanup and
queued callback cancellation. It never posts system notifications, reads
keyboard/touch input, drives the UI or changes cursors. It requires a desktop
session for WindowServer registration; `GALLERY_BUILD_ONLY=1` compiles only.

The energy/runtime harness additionally verifies completion-triggered normal
playback without any input event, a fresh idle delay, duplicate notifications,
Mission Control suppression, held-click ownership and stop. Physical switching
and final compositor timing need manual verification.

## Native language checks

```sh
bash Scripts/localization-check.sh
```

A small application bundle loads the real English and Simplified Chinese tables. Checks cover language negotiation (including fallback), numeric/filename interpolation, document metadata, stored role-name stability and translation-table placeholder parity. No system cursors or normal user preferences are changed.

## Editor checks

```sh
bash Scripts/editor-check.sh /tmp/gallery-editor-check
```

Use a fresh directory. This verifies isolated libraries, per-theme sizes, 25% bounds, drag ordering, pending saves, material variants, mixed/native roles, role aliases, covers, rename and whole-theme deletion. It does not enable cursors, change login items or modify the normal user library.

Pixel-art checks cover independent theme settings, preserved source assets, preview-cache invalidation, deferred automatic saves, and immediate navigation after changing appearance.

## Manual updates and material previews

```sh
bash Scripts/update-check.sh
bash Scripts/import-preview-check.sh
```

The update harness uses local URLProtocol fixtures by default: no automatic requests, single-flight checks, local/stable numeric version comparison, offline/HTTP failures and cancellation. An explicit `bash Scripts/update-check.sh --live` performs an anonymous read of the official repository's latest stable release. Repository identity uses the permanent numeric ID, so account or repository renames do not break the request.

In-app download checks additionally cover official asset URLs and digests,
checksum-file fallback, streamed 2 MiB metadata limits, streamed download integrity, atomic destination
replacement, invalid content/size/status, cancellation without partial files,
settings dismissal, progress throttling and credential-free HTTPS redirects restricted to GitHub release hosts.
The harness builds only its library/test targets, without a new Gallery.app.
See [update downloads](UPDATES.md) for the behavior and limits.

The material-preview harness uses generated checkerboard artwork. It verifies nearest-neighbor downsampling in pixel mode, separate smoothing cache entries, bounded image size, rejection of invalid data, and releasing cached frames when the preview closes. Neither check changes system cursors.

`bash Scripts/preferences-check.sh` additionally verifies language selection and relaunch behavior in a disposable preferences domain. It requires a desktop session and permission to write its own test preferences; the normal Gallery preferences are left unchanged.

## Windowless startup checks

```sh
bash Scripts/startup-check.sh /tmp/gallery-startup-check
```

Requires a desktop session and permission to write a disposable preferences domain. A menu-bar-only SwiftUI app uses the production delegate and store with an isolated library and a cursor-runtime spy; it does not link the native cursor bridge. Checks cover restoring the last applied theme without an editor window, hiding only the test app's Dock icon, late store attachment, disabled preferences, missing-theme fallback, recovery protection, pending documents and repeated launch/reopen callbacks. The test does not register login items or restart macOS.

## Frame-cache and confirmation scheduling checks

```sh
bash Scripts/energy-check.sh
```

This compiles library targets and a standalone test executable, without creating
Gallery.app or an installation archive. Native checks allocate only unselected,
connection-local slots; input scheduling uses an unregistered runtime. No global
cursor replacement, OS input injection, user preferences or login items are
changed, so an existing Gallery session can remain running. Checks cover a
240-frame loop, cache bounds and active-frame retention, shared resources with
independent role recovery, raster geometry/resolution/smoothing, and immediate
button/role updates despite coalesced shake movements. See
[energy optimization notes](ENERGY-OPTIMIZATION.md) for scope and preview work.

Scene-activity checks cover short/long idle returning to Normal on Space and
Mission Control edges, suppression while Mission Control remains active, a fresh
idle delay afterward, ignored Space-start guesses, and unchanged mouse-down/
mouse-up ownership. Input positions/counters are isolated from actual mouse use.
These injected edges do not automate physical multi-finger gestures.

### Experimental native loops

```sh
bash Scripts/native-loop-check.sh
```

This creates only unselected connection-local cursor slots. It checks complete
short normal/idle/hold loops, bounded 24-frame segments for longer normal/hold loops,
source-clock handover, late fallback, ownership/recovery, role independence,
cache limits and invalidation of pending background work after stop. It never
selects a cursor, registers a global replacement or hides the pointer. The
original Arrow, IBeam and Wait resources are compared before and after.
For that final equality assertion, other cursor-replacement apps must be stopped;
an actively animating global Arrow is not a stable baseline. The harness reports
the changed identifiers/fields rather than treating every mismatch as its own write.
It also rejects strips with matching first/middle/last poses but a different
middle frame order, and checks long idle fallback over repeated source wraps.

Desktop review must separately compare optimized and compatibility playback,
especially long-loop seams, interrupted hold/idle, rapid role changes and
foreground apps that cache older cursor resources. The two language previews
have isolated library copies and a shared runtime lock/recovery journal;
only one may apply or recover system cursors at a time. Stop before changing
the preview's optimization control. Earlier overlay previews also offered a
2/5-second busy-detection control; the native-Wait preview no longer uses it. The 1.1.0 release incorporates the accepted local desktop changes; future runtime changes still need visual review.

## System cursor checks

Stop and quit any running cursor replacement first. These checks temporarily replace system resources and keep an independent recovery journal in the supplied directory. Run them sequentially, with a compatible `.gallery` fixture:

```sh
bash Scripts/runtime-check.sh /tmp/gallery-runtime-check /path/to/theme.gallery
bash Scripts/settings-check.sh /tmp/gallery-settings-check /path/to/theme.gallery
```

The settings fixture must include the expected 32-point geometry, animated roles and an alternate static text variant. Checks cover visible frame progression, press/hold/release continuity, stale observation rejection, resizing, appearance, active-theme edit isolation and restoration. They do not move the pointer or post OS input events. A passing controlled check does not prove every foreground application behaves correctly.

The runtime harness additionally uses synthetic arrow/text/link assets to verify role isolation through both observed mouse-up and physical-state reconciliation, before running the supplied theme's drag, animation and restoration checks.
To run just those synthetic click-isolation checks, append `--role-clicks-only` to the runtime-check command. The theme argument remains positional but is not opened in this mode.

## Desktop review before release

Review arrows, text and links while stationary and moving in native and third-party apps. Test rapid clicks, held drags and release, idle, resize dividers, Dock, Mission Control, Spaces/full screen, custom application cursors, shake-to-enlarge, changing size, import previews, stop/quit and recovery. The application supplies the native role; Gallery does not inspect page contents to infer links. Some applications intentionally choose an arrow in editable text.

Performance measurements must preserve theme, scale, frame rate and observation mode. Report CPU separately from WindowServer and from energy use. A callback or resource-preparation timing is not physical input-to-display latency. See [1.0 measurements](PERFORMANCE-1.0.0.md).

## Release package

```sh
GALLERY_UNIVERSAL=1 bash Scripts/build.sh
```

Local four-part previews can be packaged separately without changing the formal
source version or overwriting `dist`:

```sh
GALLERY_UNIVERSAL=1 GALLERY_LOCAL_VERSION=1.0.3.7 GALLERY_LOCAL_BUILD=35 \
  GALLERY_OUTPUT_DIR=/tmp/gallery-local-package bash Scripts/build.sh
```

Verify both Mach-O architectures, signatures after unzip, embedded helper launch, version, dependency paths, required fonts/licenses and archive integrity. Search the final shipped binaries and documentation for local user paths and private fixture names. Keep debug symbols, credentials, recovery journals and third-party artwork outside the published archive.

Releases are ad-hoc signed unless a Developer ID identity is supplied. This does not imply notarization. A push to `main` builds and checks an artifact; it does not automatically publish a release.

## Theme mapping

```sh
bash Scripts/mapping-check.sh
```

Uses a temporary theme library and runtime spy, without replacing system
cursors. Checks cover mapped text/vertical-text independence through real editor
operations, directional resize/hand/drag independence, true alias synchronization,
selection toggling and save-prompt order, persistence, stale-window
and active-theme guards, bounded preview caches, pixel/shadow behavior, and
original artwork isolation from live cursors/theme recovery files, local OS PDF
cache construction, reuse, OS invalidation, corrupt header/image rebuilding,
complete compatibility fallback and 46-role coverage,
Retina resolution, correct horizontal/vertical text artwork, stable native
animation canvases and adaptive theme cropping, and a hidden native
viewport moving from the top to a deep scroll position and back. Core checks cover
legacy-to-detailed mapping archives, real local-archive compaction without changing
imported files, all 32 alternatives, reference validation, and two-way stable
card placement, source-first native grouping and crossing removal over repeated
binding changes. Verify first-use guidance, live variant popovers, hollow ports,
light/dark connections and the two separate save sheets in the native UI.
These checks do not validate global playback for the expanded catalog or native
Wait restoration. See [cursor mapping](CURSOR-MAPPING.md).

### Native resource sampling and recovery records

`bash Scripts/native-recovery-check.sh` uses synthetic 1/2/24/30/72/240-frame
strips without registering any cursor. It compares every selected frame's pixels,
geometry and cycle, verifies full raw Wait preservation, mismatched version-2
journal rejection and legacy records. Optional absolute paths to the accepted
raw 30-frame and restored 24-frame lab resources verify that product sampling
matches that exact result. This does not establish reliable crash or desktop
restoration. The preview must still be tested through Apply, Stop and normal Quit.


The mapping checks also cover consumed endpoint selection, Undo and undoable
import reset, source-name sidebar grouping with independent destination edits,
retained unassigned sources, eased scrolling without overshoot, manual-scroll
cancellation and reduced-motion positioning. Before packaging, review connection
highlight/double-click behavior, pressed ports, resized cards and both fixed-size
thumbnail confirmation sheets in the native preview.

Adaptive material checks scan the visible union of all frames without changing
source bytes or timing. They verify per-material fit, logical-point scale
clustering (125% and 127% both use 125%), a non-chaining two-percent boundary,
invalid factors and preview-stage limits. Source navigation checks include
repeated requests, invalid source IDs and scroll requests issued before the
native scroll view attaches. Hidden production SwiftUI captures can additionally
verify navigation from a deep scroll back to the requested source.

### Busy cursor overlay and status publication

`bash Scripts/wait-overlay-check.sh` exercises the actual overlay controller
with synthetic images and spy hide/show/background operations. It uses only
its own nonactivating AppKit window, verifies the actual WindowServer hotspot,
and tests ownership, pre-existing cursor hiding, recovery, suspension, invalid
owners, failed hide calls, duplicate presentation and queued-movement cleanup.
It does not rewrite or hide the user's system cursor.

The energy harness additionally checks the real CursorRuntime handover to and
from this overlay, independent click phases, live scale and status publisher
isolation. Manual bounded eight-second target tests verified automatic PRTS
playback, repeated handover after rearming the one-shot observer, and native
cursor restoration when leaving the hung window. Original Wait resources
remained equal before and after. A brief native busy flash on window entry
remains possible; no claim of completely flicker-free interception is made.

## Native import parser security checks

```sh
bash Scripts/lzma-check.sh
```

Run after building the helper (the script reuses its pinned dependency headers
and static liblzma). Synthetic tests compile the actual vendor decoder and
metadata reader. They reject huge/truncated strings and excessive LZMA1/LZMA2
dictionary requests, and round-trip normal bounded streams. They do not execute
an installer or replace cursors. See [the 1.1.0 security review](SECURITY-1.1.0.md).

The packaged icon is the reviewed `Resources/Gallery.icns`, shared unchanged
with accepted local builds. `Scripts/make-icon.swift` can regenerate its source
iconset during development; run iconutil separately and review it before
replacing the checked-in resource. Builds do not depend on host SF Symbols artwork.
