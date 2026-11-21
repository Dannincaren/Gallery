# Native cursor reference previews

Artwork: macOS system cursors, copyright Apple Inc.

Source system: macOS 27.2.1, build 26B131. The 46 role identities follow
`NativeCursorCatalog`. Available OS-owned PDF cursor files provide the vector
glyphs. Legacy roles without separate files use a verified original system-slot
archive captured before theme substitution. No theme cursor is a source.

On first launch a utility worker reads available PDF artwork from the local
read-only macOS cursor folder, renders the original glyphs and caches all 46
roles under `~/Library/Caches/<bundle identifier>/NativeCursorPreviews-v2.plist`.
No network download, extra permission or background polling is involved. On the
development Mac, 40 roles have a PDF source. A system-version/recipe change or
invalid cache rebuilds it; inability to write a cache still permits in-memory
previews.

The bundled version-1 binary plist supplies the six fileless roles and a
compatibility fallback for any unavailable PDF. Its 40 file-backed entries use
up to 64 pixels per edge; the six fileless entries retain their original
192-pixel maximum. It is 646,122 bytes after lossless PNG recompression, rather than 1,297,445 bytes (the archive
alone, not the application download). Generated PDF previews retain up to 192
pixels per edge for the 72-point Retina stage. Every animation shares one
visible-content crop and keeps its frame count, order and duration, including
all 30 Wait preview frames. Row/column crossbars retain their shared sizing.

Neither source reads live cursor registrations, NSCursor accessors or recovery
journals, so running a theme cannot contaminate these reference images. These
cropped/resized previews never overwrite or restore system resources. Recovery
uses separate, full-size raw backups. If both a PDF and its bundled reference
are unavailable, the UI leaves the preview unavailable.

SHA256 of `NativeCursorPreviews.plist`:
`c05c93de92837f3ab77ed62d63abfb61db0bc374fda515450d0f5e9e5a892a3e`

The lossless 1.1.0 recompression was checked across all 46 roles and 108 frames: decoded RGBA pixels, frame order, timing and geometry are identical.
