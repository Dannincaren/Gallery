# Theme overview and cursor mapping

Click the theme heading at the top of the role sidebar to open its overview.
Pixel style and overall theme size live here, together with rename, Gallery and
Mousecape export, whole-theme deletion, and the separate mapping window.
Role-specific animation and hotspot controls remain in each role page.

The left column lists detailed macOS cursor slots, initially in system order. Text and
vertical text, open and closed hands, pointing and drag-link cursors, column and
row resizing, and individual frame-resize directions stay separate. Only names
for the same OS slot are aliases. The current catalog contains 46 destinations;
legacy slots without a public descriptive name retain their system number.
Preview artwork is generated once from the local read-only macOS PDF cursor
files and cached by OS version. The compact bundled `NativeCursorPreviews.plist`
supplies fileless glyphs and compatibility fallbacks. All 46 references remain
independent of the live registration bank, NSCursor accessors and theme recovery
journals; running another theme cannot change them. Generation runs on a utility
worker without network access, new permissions or polling. A system/recipe
change or invalid cache rebuilds it. Generated previews retain up to 192 pixels
per edge, all native frames (including Wait's 30 preview frames) and a shared
visible-content crop per animation. See the resource provenance note for the
64-pixel compatibility fallback and source details.
The display crop never changes source artwork or live hotspots. These images
are preview-only and do not participate in cursor registration or restoration.
Dark appearance gives native images a light preview stage so black system glyphs
remain readable without recoloring them. An unavailable image is identified instead of substituting
an unrelated cursor.

The right column retains imported sources, including Windows-only and
unclassified assets. Square showcases use blue selection outlines; clicking a
selected showcase again clears that selection. Choose either side and then the
other to bind or replace a destination. The rounded-square ellipsis opens a
material preview with live playback and a list of Normal alternatives.
Click a connection to toggle its highlight; a double-click removes it. Its
accessibility Unbind action is also available. Connecting or disconnecting clears
card selection. Only one endpoint can stay selected across both columns.
Ports remain hollow. Connections are dark gray in light appearance and warm
white in dark appearance. A source moves toward its bound destinations, while
a two-way spacing pass prevents overlaps. Unbinding retains its last preferred
position. Source placement has priority. If connections still cross, only bound
native cards reorder by source group; unbound cards retain their original slots
and order within each group remains stable. The mapping board uses 160 pt square cards, a 390 pt column gap and 6.5 pt
connections, with a 780 pt minimum window width. Native previews use a square
viewport; row-resize variants share crossbar width and column-resize variants
share bar height. Material cards ignore custom theme/role scale and independently fit
the visible union of their animation to the preview stage. Factors within 2% of
the smallest member share that smaller factor, measured in logical points rather
than raster pixels. Groups never chain through successive near matches. Source
frames, timing and live cursor geometry stay unchanged. Ports sit outside the pressed button label and keep
an opaque background, so a pressed card cannot reveal the line beneath a port.

The first mapping visit opens a detailed guide; the info-circle button reopens
it later. Save, Undo and Restore Import Mapping are at the upper right. Undo retains at
most 64 mapping snapshots with shared image data. Restore infers the original
assignments from retained source roles and can itself be undone; previously
deleted materials cannot be recovered. Neither action changes global theme
size or pixel style. Closing an edited draft asks before
abandoning it; editing does not change the stored theme until Save.

One source can supply several destinations. Saving creates independent
`CursorRole` value copies under the destination OS identifiers, including
Normal, Idle, Press, Hold, Release, variants, size and idle timing. Selecting a
Normal alternative changes only Normal. Subsequent text, hand or directional
resize edits do not change other destinations that started with the same source.
Only true aliases of one OS slot share settings. Reopening and saving an
unchanged binding preserves each destination's existing edits. Previously saved
mapping archives migrate from the old family grouping to the detailed catalog.
Themes that have never used mapping retain their prior grouping and behavior.

Unbound destinations retain their original OS cursor. At least one binding is
required to save. If destinations are unpaired, a first sheet lists them and
asks whether to continue with native cursors. A separate second sheet appears
only when unused sources remain, offering Keep and Save, Delete and Save, or
return to editing. A complete mapping with no unused sources saves directly. Both confirmation
sheets are fixed at 600 × 540 pt and contain internally scrolling thumbnail/name
rows; they do not grow the parent window.
Deleting removes unused sources from the current theme's local archive and
omits unreferenced PNG data on encoding. Shared images and a referenced custom
cover remain. Original imported installers, archives and folders, and other
themes, are never changed. The portable archive deduplicates image bytes across
source metadata and independent destination copies.

Only visible previews animate, at the source's elapsed time with a 30 fps display
cap. Inactive/occluded windows, guides and save sheets pause board playback;
still images remain visible in inactive windows and after scrolling. A native
clip-view observer follows the actual viewport. First-frame loading is independent
of visibility, while animation remains limited to visible cards. Decoding and shadow rendering
use a window-local actor with a hard 128-image / 24 MiB cache, released on close.

Run `bash Scripts/check.sh` and `bash Scripts/mapping-check.sh` for archive
migration and compaction, copy independence, variant limits, selection and save
sequence, editor operations, stale/active-theme protection, raster-cache and
read-only native-artwork, stable crop and hidden scroll-viewport checks. Core
layout tests also exercise interleaved groups and repeated bind/unbind changes. The latter uses a runtime spy and a temporary
theme library, with no global cursor writes. Review native UI in both languages,
including first-use guidance, replacement and unbinding, card movement, variant
preview, scrolling, save prompts and cancellation before release.

Version 1.1.0 uses a separately backed-up, at-most-24-frame Wait resource; its restore
is an explicit approximation of the original 30-frame cycle. Read-only mapping
previews continue showing all 30 original frames. See WAIT-OVERLAY.md for the
accepted isolated test and recovery limits. These
UI references are never used as restoration resources.


The role sidebar groups by the theme's retained source names, with one row per
source even when several native destinations use it. Unassigned sources remain
in the sidebar with their original thumbnail; selecting one opens mapping,
scrolls to its source card and selects it without binding. Repeated navigation
also works in an already-open mapping window. The role-page destination picker
has been removed. Sidebar grouping never merges stored role settings.

Native cards show the public AppKit name plus a functional description; where
there is no confirmed public name, the raw identifier is retained. Parameterized
resize names use a compact argument notation. In particular, slot 39 is not a
publicly named “system 39 resize” feature, and the IBeamXOR image on this machine
is only a red-square readout, not a verified everyday text-cursor preview. See
Apple's [NSCursor reference](https://developer.apple.com/documentation/appkit/nscursor/).

After a connection change moves its native card substantially, the board scrolls
toward that card over 0.6 seconds using a quintic easing curve. Manual live scrolling
cancels the follow immediately, reduced-motion follows without animation, and no
scroll timer remains active at rest. Whole-theme and role size previews use actual
cursor geometry with a 136 pt base canvas, expanding as needed up to 256 pt.


Connection selection runs on the first local mouse-down in this window. Only a
consecutive system double-click on the same line disconnects; card events pass
through normally. A successful pair highlights its connection immediately, and
empty-space clicks clear all selections. Selected connections render above other
connections, below the opaque ports. The local monitor is removed with the view
and does no work on movement or at rest.
