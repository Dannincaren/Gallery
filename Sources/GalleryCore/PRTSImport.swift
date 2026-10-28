import Foundation

/// Compatibility entry point for existing callers; the importer now also
/// accepts other supported Windows cursor installers and loose cursor ZIPs.
public enum PRTSImport {
    public static func load(_ url: URL) throws -> GalleryTheme { try WindowsThemeImport.load(url) }
}
