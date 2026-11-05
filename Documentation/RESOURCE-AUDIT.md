# Cursor material verification

Gallery reads Windows packages as data. Compatibility checks use both synthetic fixtures in the repository and legally obtained local examples that are not redistributed.

For an unfamiliar installer, first identify the container (managed PE resources, .NET single-file manifest, Inno Setup or ZIP). Compare the imported cursor count, role mapping, variants, frame order, hotspots, geometry and duration against the extracted CUR/ANI. Round-trip the resulting Gallery archive and compare it again. Wallpaper and application icons should not enter the theme.

Animations may legitimately share images across normal, press, hold and release states. A matching image alone does not identify the current gesture or playback position. Tests must include interaction state and submission identity; do not treat duplicate frames as proof of a source defect.

For visual playback faults, use a numbered original test animation with distinct states, keep scale and shake settings fixed, and compare the actual system image with the app preview. The native cursor presentation path can differ from preview even when imported frames are identical. Short normal loops and the paired-frame update path must preserve animated resource semantics.

Import and archive tests cannot replace desktop checks of dragging, focus changes, role transitions and restoration. Private source packages, author artwork and local diagnostic recordings are excluded from the public project.
