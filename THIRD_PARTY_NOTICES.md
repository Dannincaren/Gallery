# Third-party notices

Gallery is a noncommercial extension of Mousecape, not an official Mousecape release.

Mousecape: Copyright (c) 2013-2014 Alex Zielenski, all rights reserved.
Source: https://github.com/alexzielenski/Mousecape
The original license is reproduced without modification in LICENSE. Its
noncommercial and nonmonetary conditions apply to the Mousecape-derived work.
Except for the separately licensed components below, Gallery additions are distributed under the same conditions, with original
attribution retained. Public source availability does not remove these terms.

CGSInternal headers in Vendor/Mousecape also retain their individual notices
crediting Alacatia Labs, Joe Ranieri and Alex Zielenski. See each header.

User-imported cursor themes and Windows installers are supplied locally by the
user and are not bundled with Gallery. Reading a package does not grant rights
to redistribute its artwork. Obtain material separately and retain its rights
notices. The built-in demonstration is drawn by Gallery and contains no
third-party theme artwork.

The native macOS cursor reference previews, locally cached from OS-owned files
with compatibility artwork in Resources/NativeCursorPreviews.plist, are Apple
artwork, copyright Apple Inc. They are included only as reference
images in the mapping interface, with transparent padding cropped and previews
resized for display. They are not Gallery-created theme artwork or runtime
replacement resources. See Resources/NativeCursorPreviews.md for provenance.

Gallery’s title uses the unmodified UnifrakturMaguntia font, copyright (c)
2010 j. 'mach' wust and (c) 2009 Peter Wiegel. The font remains under the
SIL Open Font License 1.1; see Resources/Fonts/UnifrakturMaguntia-OFL.txt.
Source: https://github.com/google/fonts/tree/main/ofl/unifrakturmaguntia

The separate GalleryInno import helper includes innoextract (Daniel Scharrer,
zlib license), Johannes Schindelin's Inno 6.4–7.0 compatibility changes
(https://github.com/dscharrer/innoextract/pull/210, pinned commit
376a13e7c41cc5528b6088d0dd16ec1b323a8d37), and Gallery's bounded cursor-only
extraction changes, metadata allocation limits and decoder memory bounds, also
under the zlib license. Original sources and change
notes are retained in Vendor/Innoextract. The helper never runs the Windows
installer and runs only during import.

GalleryInno statically links Boost 1.85.0 (Boost Software License 1.0) and
liblzma from XZ Utils 5.8.4 (BSD Zero Clause License, copyright the XZ Utils
authors and contributors). It does not include the GPL-licensed XZ scripts.
License texts are in Resources/ThirdParty and copied into the application.
