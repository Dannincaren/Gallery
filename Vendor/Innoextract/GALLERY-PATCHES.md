# Gallery cursor-only helper

Based on dscharrer/innoextract, with Johannes Schindelin’s Inno 6.4–7.0 compatibility branch, pinned at `376a13e7c41cc5528b6088d0dd16ec1b323a8d37` (upstream PR #210).

Gallery modifications: `--gallery-cursors` filters before extraction; only CUR/ANI and small INF files are written; unrelated directories are skipped; selected paths reject absolute/traversal components; 40 MB per asset, 160 MB across the package and 1,000 files. Existing per-theme 80 MB budget remains in Gallery. All original licensing notices are retained.

The Windows installer is never executed. The helper is a separate native macOS executable, invoked only while importing.

Gallery cursor mode also distinguishes modern per-file verification metadata from the legacy GOG multipart digest: fvNone/ISSig are not treated as an output content hash; fvHash uses the actual native data size. Native data-entry hashes and declared output sizes are checked strictly during cursor extraction.

Gallery-specific helper patches are distributed under the same zlib license as the upstream helper.
