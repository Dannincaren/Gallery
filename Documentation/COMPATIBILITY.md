# Import compatibility

Gallery reads cursor packages as inert data. It never executes an EXE, DLL or INF action.

| Format | Details |
| --- | --- |
| CUR | PNG and supported DIB payloads, transparency mask and hotspot |
| ANI | RIFF cursor animation, sequence/rate chunks; preserves timing, including terminal-hold handling for interaction material |
| INF | UTF-8, UTF-16, common legacy Chinese/Windows encodings; role declarations and bounded string substitutions |
| ZIP | Stored/Deflate, ZIP64, Unicode path metadata, UTF-8 and common legacy Chinese names; streams selected entries and validates CRC |
| Managed EXE | PE32/PE32+ managed ManifestResource entries containing CUR/ANI/INF |
| .NET single-file | Bundle manifest versions 1, 2 and 6, including raw-Deflate assemblies and duplicate ReadyToRun material |
| Inno Setup | Versions supported by the included native import helper, including its retained compatibility updates |
| ZIP self-extractor | ZIP data appended to an executable; only archive content is decoded |
| Gallery / Mousecape | Portable Gallery settings and variants; Mousecape normal-state resources |

ZIP compression methods beyond stored/Deflate use the system extractor when available. Other executable packers, encrypted material, externally downloaded assets and damaged or incomplete packages may need manual extraction first. This is not a claim of support for every Windows executable.

Independent configured subfolders are offered as separate themes. Multiple materials for one role remain selectable variants. A standalone cursor with an unrecognized filename defaults to normal selection; unclassified files in a larger set remain editable material.

## Bounds

- Outer ZIP/EXE: 2,000,000,000 bytes.
- A cursor file: 40 MB; an INF: 1 MB.
- Ordinary cursor sets: 80 MB and 1,000 input material/config files; up to 80 roles/unclassified items per theme.
- Inno and managed-bundle extraction use separate bounded totals; a single managed assembly is limited to 80 MB and inspected assemblies to 160 MB.
- ZIP entries: 50,000; imported configured sets: 80; per-action material variants: 32.
- Gallery archives: 80 MB. Cursor frame count, bitmap size, logical geometry and hotspots are checked independently.

Archive links, traversal paths, multi-volume ZIPs, inconsistent lengths and corrupt selected cursor checksums are rejected. Only cursor material and required configuration are retained. Temporary extracted installers are removed after the import attempt; original input files are not changed.
