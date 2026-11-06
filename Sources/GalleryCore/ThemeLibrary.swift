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
    public var cover: Data?
    public var coverKey: String?
    public var appearance: CursorAppearance?
    public init(id: String = UUID().uuidString, theme: GalleryTheme) {
        self.id = id; name = theme.name; appearance = theme.appearance
        var names = Set<String>()
        roles = theme.roles.filter { names.insert(CursorCatalog.family($0.id)).inserted }.map(LibraryRole.init)
    }
}

/// The index contains labels and small cached thumbnails; animation frames
/// stay in standalone theme archives, which remain portable when roles mix.
public enum ThemeLibrary {
    private static let previewVersion = "3:"
    public static func needsThumbnails(_ row: LibraryTheme) -> Bool {
        let hasCover = row.cover != nil || row.roles.contains(where: { CursorCatalog.isArrow($0.id) })
        return hasCover && (row.cover == nil || row.coverKey?.hasPrefix(previewVersion) != true)
            || row.roles.contains { $0.thumbnail == nil || $0.thumbnailKey?.hasPrefix(previewVersion) != true }
    }
    /// Called on the file queue, never in a SwiftUI body or cursor callback.
    /// A persisted 64px image avoids retaining full animation frames per row.
    public static func thumbnails(id: String, theme: GalleryTheme, previous: LibraryTheme?) -> LibraryTheme {
        var row = LibraryTheme(id: id, theme: theme)
        var decoded: [Data: CGImage] = [:]
        func geometry(for frame: Data) -> CursorClip {
            for role in theme.roles { for clip in role.clips.values where clip.frames.contains(frame) { return clip } }
            let image = try? CursorImages.bitmap(frame)
            let width = Double(image?.width ?? 32), height = Double(image?.height ?? 32)
            let ratio = min(1, 128 / max(width, height))
            return CursorClip(frames: [frame], width: width * ratio, height: height * ratio)
        }
        func key(_ frame: Data, _ clip: CursorClip) -> String {
            var hash = SHA256(); hash.update(data: frame)
            hash.update(data: Data("\(theme.appearance.effectiveSmoothEdges):\(theme.appearance.shadow):\(clip.width):\(clip.height)".utf8))
            return previewVersion + hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func thumbnail(_ frame: Data, _ clip: CursorClip, maximum: Int) -> Data? {
            if decoded[frame] == nil { decoded[frame] = try? CursorImages.bitmap(frame) }
            guard let image = decoded[frame] else { return nil }
            let padding = theme.appearance.shadow ? 4.0 : 0
            let width = clip.width + 2 * padding, height = clip.height + 2 * padding
            let scale = min(Double(maximum) / max(width, height), Double(image.width) / clip.width)
            let pixelsWide = max(1, Int((width * scale).rounded())), pixelsHigh = max(1, Int((height * scale).rounded()))
            guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: pixelsWide * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = theme.appearance.effectiveSmoothEdges ? .high : .none
            context.setShouldAntialias(theme.appearance.effectiveSmoothEdges)
            if theme.appearance.shadow {
                context.setShadow(offset: CGSize(width: 0, height: -scale), blur: 1.5 * scale, color: CGColor(gray: 0, alpha: 0.32))
            }
            context.draw(image, in: CGRect(x: padding * scale, y: padding * scale, width: clip.width * scale, height: clip.height * scale))
            return context.makeImage().flatMap { try? CursorImages.png($0) }
        }
        if let frame = theme.coverFrame ?? theme.roles.first(where: { CursorCatalog.isArrow($0.id) })?.clip(.normal)?.frames.first {
            let clip = geometry(for: frame), key = key(frame, clip)
            row.coverKey = key
            if previous?.coverKey == key, let cover = previous?.cover { row.cover = cover }
            else { row.cover = thumbnail(frame, clip, maximum: 192) }
        }
        for i in row.roles.indices {
            guard let role = theme.roles.first(where: { $0.id == row.roles[i].id }), let clip = role.clip(.normal), let frame = clip.frames.first else { continue }
            let key = key(frame, clip)
            if let old = previous?.roles.first(where: { $0.id == role.id }), old.thumbnailKey == key, old.thumbnail != nil {
                row.roles[i].thumbnail = old.thumbnail; row.roles[i].thumbnailKey = key; continue
            }
            guard let png = thumbnail(frame, clip, maximum: 64) else { continue }
            row.roles[i].thumbnail = png; row.roles[i].thumbnailKey = key
        }
        return row
    }
    public static func loadIndex(at url: URL) throws -> [LibraryTheme] {
        let rows = try JSONDecoder().decode([LibraryTheme].self, from: Data(contentsOf: url))
        guard rows.count <= 200, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw ThemeError.invalid(L("主题目录索引无效。")) }
        return rows
    }
    public static func saveIndex(_ rows: [LibraryTheme], at url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: url, options: .atomic)
    }
    public static func applyTemplate(_ template: CursorRole, sourceName: String, to identifier: String, in theme: inout GalleryTheme) throws {
        guard let target = theme.roles.first(where: { $0.id == identifier }) else { throw ThemeError.invalid(L("找不到目标光标。")) }
        var updated = theme
        for index in updated.roles.indices where CursorCatalog.family(updated.roles[index].id) == CursorCatalog.family(target.id) {
            updated.roles[index].clips = template.clips
            updated.roles[index].variants = template.variants
            updated.roles[index].selectedVariants = template.selectedVariants
            updated.roles[index].usesNative = false
            updated.roles[index].sourceThemeName = sourceName
        }
        try updated.validate(); theme = updated
    }
}
