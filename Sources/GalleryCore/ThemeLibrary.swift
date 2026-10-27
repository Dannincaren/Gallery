import Foundation

public struct LibraryRole: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var motionCount: Int
    public var usesNative: Bool
    public init(_ role: CursorRole) {
        id = role.id; name = role.name; motionCount = role.clips.count; usesNative = role.usesNative
    }
}
public struct LibraryTheme: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var roles: [LibraryRole]
    public init(id: String = UUID().uuidString, theme: GalleryTheme) {
        self.id = id; name = theme.name
        var names = Set<String>()
        roles = theme.roles.filter { names.insert($0.name).inserted }.map(LibraryRole.init)
    }
}

/// The index contains only labels, never duplicated bitmap data. Theme files
/// are standalone archives and remain portable when roles are mixed.
public enum ThemeLibrary {
    public static func loadIndex(at url: URL) throws -> [LibraryTheme] {
        let rows = try JSONDecoder().decode([LibraryTheme].self, from: Data(contentsOf: url))
        guard rows.count <= 200, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw ThemeError.invalid("主题目录索引无效。") }
        return rows
    }
    public static func saveIndex(_ rows: [LibraryTheme], at url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: url, options: .atomic)
    }
    public static func applyTemplate(_ template: CursorRole, sourceName: String, to identifier: String, in theme: inout GalleryTheme) throws {
        guard let target = theme.roles.first(where: { $0.id == identifier }) else { throw ThemeError.invalid("找不到目标光标。") }
        var updated = theme
        for index in updated.roles.indices where updated.roles[index].name == target.name {
            updated.roles[index].clips = template.clips
            updated.roles[index].splitClickAnimation = template.splitClickAnimation
            updated.roles[index].usesNative = false
            updated.roles[index].sourceThemeName = sourceName
        }
        try updated.validate(); theme = updated
    }
}
