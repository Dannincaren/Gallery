import Foundation
import CryptoKit

/// Version 2 stores identical PNGs once. A complete PRTS theme contains many
/// system aliases and repeated ANI frames; embedding those bytes per role made
/// a portable theme needlessly large. Version 1 remains readable.
struct ThemeArchive: Codable {
    var formatVersion = 2
    var name: String
    var author: String
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
        var clips: [String: Clip]
    }
    struct Clip: Codable {
        var frames: [String]
        var frameDuration: Double
        var width: Double
        var height: Double
        var hotX: Double
        var hotY: Double
    }
    init(_ theme: GalleryTheme) {
        name = theme.name; author = theme.author; idleDelay = theme.idleDelay
        idleEnabled = theme.idleEnabled; clickEnabled = theme.clickEnabled; excludedBundleIDs = theme.excludedBundleIDs
        var pool: [String: Data] = [:]
        roles = theme.roles.map { role in
            let clips = role.clips.mapValues { clip in
                let keys = clip.frames.map { data -> String in
                    let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    pool[key] = data; return key
                }
                return Clip(frames: keys, frameDuration: clip.frameDuration, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY)
            }
            return Role(id: role.id, name: role.name, splitClickAnimation: role.splitClickAnimation,
                        scale: role.scale, usesNative: role.usesNative, sourceThemeName: role.sourceThemeName, clips: clips)
        }
        images = pool
    }
    func theme() throws -> GalleryTheme {
        guard formatVersion == 2, images.count <= 12000, roles.count <= 80 else { throw ThemeError.invalid("主题资源数量无效。") }
        let decoded = try roles.map { role -> CursorRole in
            let clips = try role.clips.mapValues { clip -> CursorClip in
                guard clip.frames.count <= 240 else { throw ThemeError.invalid("动画帧过多。") }
                let frames = try clip.frames.map { key -> Data in
                    guard let bytes = images[key] else { throw ThemeError.invalid("主题缺少帧图像。") }
                    return bytes
                }
                return CursorClip(frames: frames, frameDuration: clip.frameDuration, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY)
            }
            return CursorRole(id: role.id, name: role.name, clips: clips, splitClickAnimation: role.splitClickAnimation,
                              scale: role.scale ?? 1, usesNative: role.usesNative ?? false, sourceThemeName: role.sourceThemeName)
        }
        var theme = GalleryTheme(name: name, author: author, roles: decoded)
        theme.idleDelay = idleDelay; theme.idleEnabled = idleEnabled; theme.clickEnabled = clickEnabled
        theme.excludedBundleIDs = excludedBundleIDs
        try theme.validate(); return theme
    }
}
