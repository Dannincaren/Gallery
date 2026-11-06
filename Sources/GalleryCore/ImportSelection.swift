import Foundation

public enum ImportSelection {
    public static func key(role: String, motion: Motion) -> String { CursorCatalog.family(role) + ":" + motion.rawValue }
    public static func hasAlternatives(_ theme: GalleryTheme) -> Bool {
        theme.roles.contains { $0.variants.values.contains { $0.count > 1 } }
    }
    /// Missing keys retain all materials. Explicit empty choices remove an
    /// optional motion, while a normal cursor always needs one material.
    public static func keeping(_ selections: [String: Set<String>], in input: GalleryTheme) throws -> GalleryTheme {
        var result = input
        for index in result.roles.indices {
            for motion in Motion.allCases {
                let key = key(role: result.roles[index].id, motion: motion), raw = motion.rawValue
                guard let kept = selections[key], let alternatives = result.roles[index].variants[raw] else { continue }
                let variants = alternatives.filter { kept.contains($0.id) }
                if variants.isEmpty {
                    guard motion != .normal else { throw ThemeError.invalid(L("\(result.roles[index].localizedName)的常态至少需要保留一套素材。")) }
                    result.roles[index].clips.removeValue(forKey: raw)
                    result.roles[index].variants.removeValue(forKey: raw)
                    result.roles[index].selectedVariants.removeValue(forKey: raw)
                } else {
                    if !variants.contains(where: { $0.id == result.roles[index].selectedVariants[raw] }) {
                        result.roles[index].clips[raw] = variants[0].clip
                        result.roles[index].selectedVariants[raw] = variants[0].id
                    }
                    result.roles[index].variants[raw] = variants
                }
            }
        }
        try result.validate(); return result
    }
}
