import Foundation
import CryptoKit

/// Version 2 stores identical PNGs once. A complete animated theme contains many
/// system aliases and repeated ANI frames; embedding those bytes per role made
/// a portable theme needlessly large. Version 1 remains readable.
struct ThemeArchive: Codable {
    var formatVersion = 2
    var name: String
    var author: String
    var pointerScale: Double?
    var appearance: CursorAppearance?
    var coverFrame: String?
    var idleDelay: Double
    var idleEnabled: Bool
    var clickEnabled: Bool
    var excludedBundleIDs: [String]
    var roles: [Role]
    var images: [String: Data]
    struct Role: Codable {
        var id: String
        var name: String
        var splitClickAnimation: Bool
        var scale: Double?
        var usesNative: Bool?
        var sourceThemeName: String?
        var idleDelayOverride: Double?
        var clips: [String: Clip]
        var variants: [String: [Variant]]?
        var selectedVariants: [String: String]?
    }
    struct Variant: Codable { var id: String; var name: String; var clip: Clip }
    struct Clip: Codable {
        var frames: [String]
        var frameDuration: Double
        var width: Double
        var height: Double
        var hotX: Double
        var hotY: Double
    }
    init(_ theme: GalleryTheme) {
        name = theme.name; author = theme.author; idleDelay = theme.idleDelay; pointerScale = theme.pointerScale; appearance = theme.appearance
        idleEnabled = theme.idleEnabled; clickEnabled = theme.clickEnabled; excludedBundleIDs = theme.excludedBundleIDs
        var pool: [String: Data] = [:]
        var frameKeys: [Data: String] = [:]
        func imageKey(_ data: Data) -> String {
            if let cached = frameKeys[data] { return cached }
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            frameKeys[data] = key; pool[key] = data
            return key
        }
        func archive(_ clip: CursorClip) -> Clip {
            let keys = clip.frames.map(imageKey)
            return Clip(frames: keys, frameDuration: clip.frameDuration, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY)
        }
        roles = theme.roles.map { role in
            let clips = role.clips.mapValues(archive)
            let variants = role.variants.mapValues { $0.map { Variant(id: $0.id, name: $0.name, clip: archive($0.clip)) } }
            return Role(id: role.id, name: role.name, splitClickAnimation: role.splitClickAnimation,
                        scale: role.scale, usesNative: role.usesNative, sourceThemeName: role.sourceThemeName, idleDelayOverride: role.idleDelayOverride,
                        clips: clips, variants: variants.isEmpty ? nil : variants, selectedVariants: role.selectedVariants.isEmpty ? nil : role.selectedVariants)
        }
        if let cover = theme.coverFrame {
            coverFrame = imageKey(cover)
        } else { coverFrame = nil }
        images = pool
    }
    func theme() throws -> GalleryTheme {
        guard formatVersion == 2, images.count <= 12000, roles.count <= 80 else { throw ThemeError.invalid("主题资源数量无效。") }
        func restore(_ clip: Clip) throws -> CursorClip {
            guard clip.frames.count <= 240 else { throw ThemeError.invalid("动画帧过多。") }
            let frames = try clip.frames.map { key -> Data in
                guard let bytes = images[key] else { throw ThemeError.invalid("主题缺少帧图像。") }
                return bytes
            }
            return CursorClip(frames: frames, frameDuration: clip.frameDuration, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY)
        }
        let decoded = try roles.map { role -> CursorRole in
            let clips = try role.clips.mapValues(restore)
            let variants = try (role.variants ?? [:]).mapValues { try $0.map { CursorVariant(id: $0.id, name: $0.name, clip: try restore($0.clip)) } }
            return CursorRole(id: role.id, name: role.name, clips: clips, splitClickAnimation: role.splitClickAnimation,
                              scale: role.scale ?? 1, usesNative: role.usesNative ?? false, sourceThemeName: role.sourceThemeName, idleDelayOverride: role.idleDelayOverride,
                              variants: variants, selectedVariants: role.selectedVariants ?? [:])
        }
        var theme = GalleryTheme(name: name, author: author, roles: decoded)
        theme.pointerScale = pointerScale ?? 1
        theme.appearance = appearance ?? CursorAppearance()
        if let coverFrame {
            guard let cover = images[coverFrame] else { throw ThemeError.invalid("主题缺少封面图像。") }
            theme.coverFrame = cover
        }
        theme.idleDelay = idleDelay; theme.idleEnabled = idleEnabled; theme.clickEnabled = clickEnabled
        theme.excludedBundleIDs = excludedBundleIDs
        try theme.validate(); return theme
    }
}
