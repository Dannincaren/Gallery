import Foundation

/// Native bundle localization honors the system's preferred languages and
/// macOS's per-app language setting. Nothing observes input or polls for locale
/// changes; macOS relaunches the app after a per-app language change.
public enum GalleryLocalization {
    public static let isEnglish = !(Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")

    /// Stored role names and imported filenames are never rewritten. Known
    /// built-in labels are translated only when displayed; unknown names pass
    /// through unchanged.
    public static func label(_ name: String) -> String {
        Bundle.main.localizedString(forKey: name, value: name, table: nil)
    }
    public static func themeName(_ name: String) -> String {
        name == "Gallery · 光晕" || name == "Windows 光标主题" ? label(name) : name
    }
}

/// String.LocalizationValue retains interpolations for native string-table
/// lookup, including printf specifiers and reordered English arguments.
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .main)
}

extension CursorRole {
    public var localizedName: String { GalleryLocalization.label(name) }
}
extension LibraryRole {
    public var localizedName: String { GalleryLocalization.label(name) }
}
extension GalleryTheme {
    public var localizedName: String { GalleryLocalization.themeName(name) }
}
extension LibraryTheme {
    public var localizedName: String { GalleryLocalization.themeName(name) }
}
extension CursorVariant {
    public var localizedName: String {
        for prefix in ["动态", "静态"] where name.hasPrefix(prefix + " · ") {
            return GalleryLocalization.label(prefix) + name.dropFirst(prefix.count)
        }
        return GalleryLocalization.label(name)
    }
}
