# Troubleshooting

## A package will not import

Choose the file that actually contains cursor material, rather than a downloader or shortcut installer. Try an accompanying CUR/ANI folder or INF. Keep the files referenced by an INF beside it. Large mixed customization bundles may need to be split into cursor sets because the outer-package limit and extracted-material limits are different.

Gallery reports unsupported packing or malformed files rather than running Windows code. See [supported formats and limits](COMPATIBILITY.md). Include the error text, macOS version, package format and reproducible steps in an issue. Do not attach private themes, copyrighted installer files or personal logs without permission; a minimal original example is preferable.

## No animation or a native cursor appears

Apply the theme using the play button. Check that the role has a dynamic variant selected and that the action has frames. Some application-owned cursors cannot be mapped reliably. Gallery temporarily passes unknown cursors through and resumes on known roles. Static single-frame material has no normal-loop animation.

Input Monitoring enables session mouse listening; the fallback may behave differently across apps. Gallery does not need Accessibility permission. Stop other automatic cursor-replacement tools before testing.

## Previews do not reflect appearance

Changing smoothing or shadows regenerates static covers and role thumbnails in the background. The source artwork is not overwritten. Pause the active theme before editing appearance, then apply it again. Large libraries can take a moment to rebuild old preview caches once.

## Restore the original cursor

Use Stop and Restore in the toolbar or menu bar, or quit normally. After a crash, reopen Gallery and use the recovery action. If another tool is also replacing cursors, stop that tool first. Signing out and back in resets session resources when normal recovery is unavailable.

## Opening the app / login items

Move Gallery.app into Applications before enabling launch at login. Current releases are ad-hoc signed and not Developer ID notarized; macOS may require explicit approval in System Settings → Privacy & Security. Only approve a copy obtained from this repository's Releases. No terminal command to disable system protections is required.
