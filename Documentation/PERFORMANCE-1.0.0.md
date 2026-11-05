# Gallery 1.0.0 performance

Measured locally on 2026-11-05 using optimized builds. Priority: click responsiveness, CPU/energy, then download size. Results are comparisons on one machine, not guarantees for all Macs.

## Less repeated recognition work

A cursor snapshot now shares one fingerprint across pending-frame checks, recovery and role matching. Threshold comparisons reject impossible candidates early, then retain the original floating-point decision at the boundary. Recovery selects the earliest compatible release frame in a single pass rather than allocating temporary arrays.

An offline comparison used 83 locally supplied observations and 33,246 assertions against the previous matcher, including exact/adjacent threshold boundaries. Role results and applied-role results matched. Third-party fixture images are not distributed.

| Workload | Previous median | 1.0 median |
| --- | ---: | ---: |
| Repeated threshold comparisons | 19.69 ms | 8.37 ms |
| Snapshot fingerprint and matching workload | 12.66 ms | 9.11 ms |

These are repeated-workload timings, **not milliseconds saved on every click**. They exclude mouse hardware, macOS event delivery, WindowServer compositing and display refresh. No physical input-to-display measurement is claimed.

## Playback and energy

The proven cursor rendering path is retained: short normal loops use native system playback; longer loops and interactions reuse bounded prepared resources with two identical animation frames. Position/compositing stays in macOS. Frame rate, event sources, polling frequency, cache limits and animation timing are unchanged by this optimization.

Static gallery cards do not animate. Appearance thumbnails regenerate on the existing background save queue, once per changed appearance revision. ZIP stored/Deflate extraction reads selected content directly and streams output, removing per-file extractor launches. Wallpaper and unrelated application content are skipped.

Short desktop CPU samples vary with foreground cursor selection and cannot isolate recognition cost reliably. No fixed whole-app CPU reduction or battery-watt saving is claimed. The earlier rendering/cache improvements and their separate measurements are in [0.7.8 performance](PERFORMANCE-0.7.8.md).

## Package size without changing playback

Release copies retain both architectures and all import capabilities. Debug/local symbols are kept outside the app; symbol stripping preserves runtime code/data. ZIP compression uses level 9. The main program keeps its speed-oriented optimization; no reflection metadata, cursor frames, fonts or import formats are removed to reduce size.

Final package checks include architecture, signatures after extraction, helper startup, license/font presence and absence of private development paths. Package measurements are recorded in the release notes.

## Verification scope

Core import/interaction checks, isolated editor checks and controlled system-cursor checks complement a desktop comparison of text, links, quick clicks and drag release. Controlled timings do not replace that desktop review. Any optimization that changes playback behavior or substantially raises energy use requires a separate choice and validation.

Package: **2.36 MB ZIP**, **5.49 MB installed contents** (decimal units). Both architectures are included. New import support slightly increases the app compared with 0.7.9; level-9 compression changes no extracted file contents.
