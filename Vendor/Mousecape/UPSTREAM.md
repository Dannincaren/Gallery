# Mousecape source provenance

Upstream: https://github.com/alexzielenski/Mousecape

Pinned commit: `184f87b5d8ba52e0529f0ca8a7bd15b25b101358` (retrieved 2026-10-27).

The files in this folder are verbatim reference excerpts from upstream. They are
not compiled as a second cursor service. GalleryNative/CursorBridge.m adapts the
registration, image-copy and filmstrip approach used in upstream `apply.m` and
`MCDefs.m`, retaining the main project's noncommercial license at the repository
root. The headers carry their own notices, which are preserved verbatim.

Gallery provides a new SwiftUI interface, persistent theme format, importers and
interaction state machine. It uses the same private cursor API family; Apple
does not guarantee their future availability. It does not require a separately
installed Mousecape binary. Running two reapplication helpers is unsupported.
