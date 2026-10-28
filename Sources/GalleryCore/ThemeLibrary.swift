import Foundation
import ImageIO
import CryptoKit

public struct LibraryRole: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var motionCount: Int
    public var usesNative: Bool
    public var thumbnail: Data?
    public var thumbnailKey: String?
    public init(_ role: CursorRole) {
        id = role.id; name = role.name; motionCount = role.clips.count; usesNative = role.usesNative
    }
}
public struct LibraryTheme: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var roles: [LibraryRole]
    public init(id: String = UUID().uuidString, theme: GalleryTheme) {
        self.id = id; name = theme.name
        var names = Set<String>()
        roles = theme.roles.filter { names.insert(CursorCatalog.family($0.id)).inserted }.map(LibraryRole.init)
    }
}

/// The index contains labels and small cached thumbnails; animation frames
/// stay in standalone theme archives, which remain portable when roles mix.
public enum ThemeLibrary {
    /// Called on the file queue, never in a SwiftUI body or cursor callback.
    /// A persisted 64px image avoids retaining full animation frames per row.
    public static func thumbnails(id: String, theme: GalleryTheme, previous: LibraryTheme?) -> LibraryTheme {
        var row = LibraryTheme(id: id, theme: theme)
        for i in row.roles.indices {
            guard let role = theme.roles.first(where: { $0.id == row.roles[i].id }), let frame = role.clip(.normal)?.frames.first else { continue }
            let key = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
            if let old = previous?.roles.first(where: { $0.id == role.id }), old.thumbnailKey == key, old.thumbnail != nil {
                row.roles[i].thumbnail = old.thumbnail; row.roles[i].thumbnailKey = key; continue
            }
            guard let source = CGImageSourceCreateWithData(frame as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let png = try? CursorImages.png(image) else { continue }
            row.roles[i].thumbnail = png; row.roles[i].thumbnailKey = key
        }
        return row
    }
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
        for index in updated.roles.indices where CursorCatalog.family(updated.roles[index].id) == CursorCatalog.family(target.id) {
            updated.roles[index].clips = template.clips
            updated.roles[index].splitClickAnimation = template.splitClickAnimation
            updated.roles[index].usesNative = false
            updated.roles[index].sourceThemeName = sourceName
        }
        try updated.validate(); theme = updated
    }
}
