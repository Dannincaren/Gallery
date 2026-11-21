import Foundation
import GalleryCore

/// Run inside the tiny test app bundle so this exercises macOS's real language
/// negotiation, table loading and interpolation rather than a mock dictionary.
@main
struct LocalizationHarness {
    static func main() throws {
        let english = CommandLine.arguments[1] == "en"
        func check(_ result: Bool, _ message: String) throws {
            if !result { throw ThemeError.invalid(message) }
        }
        if CommandLine.arguments[1] == "--tables-only" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            func read(_ language: String) throws -> [String: String] {
                let data = try Data(contentsOf: root.appendingPathComponent(language + ".lproj/Localizable.strings"))
                return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            }
            let source = try read("zh-Hans"), target = try read("en")
            try check(Set(source.keys) == Set(target.keys), "Language tables have different keys")
            let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:ll|l|h)?[@dfius]"#)
            func formats(_ value: String) -> [String] {
                pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { String(value[Range($0.range, in: value)!]) }
            }
            for language in ["zh-Hans", "en"] {
                let values = language == "en" ? target : source
                let bundle = Bundle(path: root.appendingPathComponent(language + ".lproj").path)!
                for (key, value) in values {
                    try check(bundle.localizedString(forKey: key, value: nil, table: nil) == value, "Native table failed for " + key)
                    try check(formats(source[key]!) == formats(target[key]!), "Placeholder mismatch for " + key)
                }
                print("PASS \(language): native resource lookup and placeholder parity for \(values.count) entries")
            }
            return
        }
        try check(GalleryLocalization.isEnglish == english, "Incorrect language negotiation")
        try check(L("导入主题") == (english ? "Import Theme" : "导入主题"), "Missing static translation")
        try check(L("已选择 \(2) / \(3) 套") == (english ? "Selected 2 / 3 sets" : "已选择 2 / 3 套"), "Integer placeholders changed")
        try check(L("\(12.0, specifier: "%.0f") × \(16.0, specifier: "%.0f") 点 · \(0.25, specifier: "%.2f") 秒") ==
            (english ? "12 × 16 pt · 0.25 s" : "12 × 16 点 · 0.25 秒"), "Floating-point placeholders changed")
        let filename = "My %@-%lld-测试.cur"
        try check(L("无法读取素材「\(filename)」：\("detail")") ==
            (english ? "Could not read asset “\(filename)”: detail" : "无法读取素材「\(filename)」：detail"), "Imported text was interpreted as a format string")
        let clip = CursorClip(frames: [Data([1])])
        let role = CursorRole(id: "com.apple.coregraphics.IBeam", name: "文本选择", clips: ["normal": clip])
        try check(role.localizedName == (english ? "Text Select" : "文本选择"), "Stored role label not translated")
        try check(role.name == "文本选择" && CursorCatalog.all.first(where: { $0.id == role.id })?.title == role.name,
                  "Localization changed persisted names or the cursor catalog")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(role)
        _ = role.localizedName; _ = Motion.allCases.map(\.title)
        try check(try encoder.encode(role) == before, "Displaying a role changed serialized data")
        let variant = CursorVariant(id: "asset", name: "动态 · " + filename, clip: clip)
        try check(variant.localizedName == (english ? "Animated · " : "动态 · ") + filename, "Variant filename was changed")
        try check(GalleryLocalization.themeName("My 私人主题") == "My 私人主题", "User theme name was translated")
        try check(Bundle.main.localizedInfoDictionary?["CFBundleTypeName"] as? String == (english ? "Gallery Theme" : "Gallery 主题"),
                  "Document type metadata is not localized")
        // Read every native table entry to catch malformed tables, missing
        // dynamic-role keys, accidental omissions, and invalid format types.
        let root = Bundle.main.resourceURL!
        func table(_ locale: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent(locale + ".lproj/Localizable.strings"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        }
        let source = try table("zh-Hans"), target = try table("en")
        try check(Set(source.keys) == Set(target.keys), "Language tables have different keys")
        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:ll|l|h)?[@dfius]"#)
        func formats(_ value: String) -> [String] {
            specifier.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }
        }
        for (key, value) in source {
            try check(formats(value) == formats(target[key]!), "Placeholder mismatch for " + key)
        }
        print("PASS \(english ? "English" : "Simplified Chinese"): native selection, interpolation, metadata, unchanged themes and \(target.count) table entries")
    }
}
