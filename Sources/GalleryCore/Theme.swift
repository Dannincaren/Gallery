import Foundation

public enum Motion: String, Codable, CaseIterable, Identifiable {
    case normal, idle, press, hold, release
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: return "常态"
        case .idle: return "待机"
        case .press: return "按下"
        case .hold: return "按住"
        case .release: return "松手"
        }
    }
    public var loops: Bool { self == .normal || self == .idle || self == .hold }
}

public struct CursorClip: Codable, Equatable {
    public var frames: [Data]
    public var frameDuration: Double
    public var width: Double
    public var height: Double
    /// Logical points from the top-left; independent of the bitmap scale.
    public var hotX: Double
    public var hotY: Double
    public var duration: Double { Double(frames.count) * frameDuration }
    public init(frames: [Data], frameDuration: Double = 0.05, width: Double = 32,
                height: Double = 32, hotX: Double = 0, hotY: Double = 0) {
        self.frames = frames; self.frameDuration = frameDuration
        self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
    }
    public func validate() throws {
        guard !frames.isEmpty, frames.count <= 240, frames.allSatisfy({ !$0.isEmpty && $0.count <= 8_000_000 }),
              frameDuration.isFinite, (1.0 / 240...10).contains(frameDuration),
              width.isFinite, height.isFinite, (1...128).contains(width), (1...128).contains(height),
              hotX.isFinite, hotY.isFinite, hotX >= 0, hotY >= 0, hotX < width, hotY < height else {
            throw ThemeError.invalid("动画帧、大小或热点超出有效范围。")
        }
    }
    /// Mousecape's existing path accepts at most 24 equally timed frames.
    /// Preserve total duration when resampling longer clips.
    public func sampled(limit: Int = 24) -> CursorClip {
        guard limit > 0, frames.count > limit else { return self }
        var result = self
        result.frames = (0..<limit).map { frames[$0 * frames.count / limit] }
        result.frameDuration = duration / Double(limit)
        return result
    }
    /// Scale logical geometry and hotspot together, without changing the
    /// system-wide accessibility pointer size or another app's custom cursor.
    public func scaled(by scale: Double) -> CursorClip {
        guard scale.isFinite, scale > 0 else { return self }
        let factor = max(1 / min(width, height), min(scale, 128 / max(width, height)))
        var result = self
        result.width = width * factor; result.height = height * factor
        result.hotX = hotX * factor; result.hotY = hotY * factor
        return result
    }
    @discardableResult
    public mutating func duplicateFrame(at index: Int) throws -> Int {
        guard frames.indices.contains(index), frames.count < 240 else { throw ThemeError.invalid("无法复制这一帧：最多支持 240 帧。") }
        frames.insert(frames[index], at: index + 1)
        return index + 1
    }
}

public struct CursorRole: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var clips: [String: CursorClip]
    public var splitClickAnimation: Bool
    public var scale: Double
    public var usesNative: Bool
    public var sourceThemeName: String?
    public var idleDelayOverride: Double?
    public init(id: String, name: String, clips: [String: CursorClip], splitClickAnimation: Bool? = nil,
                scale: Double = 1, usesNative: Bool = false, sourceThemeName: String? = nil, idleDelayOverride: Double? = nil) {
        self.id = id; self.name = name; self.clips = clips
        self.splitClickAnimation = splitClickAnimation ?? CursorCatalog.isArrow(id)
        self.scale = scale; self.usesNative = usesNative; self.sourceThemeName = sourceThemeName
        self.idleDelayOverride = idleDelayOverride
    }
    private enum CodingKeys: String, CodingKey { case id, name, clips, splitClickAnimation, scale, usesNative, sourceThemeName, idleDelayOverride }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decode([String: CursorClip].self, forKey: .clips)
        splitClickAnimation = try c.decodeIfPresent(Bool.self, forKey: .splitClickAnimation) ?? CursorCatalog.isArrow(id)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        usesNative = try c.decodeIfPresent(Bool.self, forKey: .usesNative) ?? false
        sourceThemeName = try c.decodeIfPresent(String.self, forKey: .sourceThemeName)
        idleDelayOverride = try c.decodeIfPresent(Double.self, forKey: .idleDelayOverride)
    }
    public func clip(_ motion: Motion) -> CursorClip? { clips[motion.rawValue] }
    public func idleDelay(default global: Double) -> Double { idleDelayOverride ?? global }
}

public struct GalleryTheme: Codable, Equatable {
    public var formatVersion = 1
    public var name: String
    public var author: String
    public var roles: [CursorRole]
    public var idleDelay: Double = 8
    public var idleEnabled = true
    public var clickEnabled = true
    public var excludedBundleIDs: [String] = []
    public init(name: String, author: String = "", roles: [CursorRole]) {
        self.name = name; self.author = author; self.roles = roles
    }
    public func validate() throws {
        guard formatVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !roles.isEmpty, roles.count <= 80, Set(roles.map(\.id)).count == roles.count,
              idleDelay.isFinite, (1...600).contains(idleDelay) else {
            throw ThemeError.invalid("主题格式、角色或待机时间无效。")
        }
        for role in roles {
            if let delay = role.idleDelayOverride, !delay.isFinite || !(1...600).contains(delay) {
                throw ThemeError.invalid("角色待机等待时间应为 1–600 秒。")
            }
            guard role.id.hasPrefix("com.apple."), role.clip(.normal) != nil, role.scale.isFinite, (0.5...3).contains(role.scale),
                  role.clips.keys.allSatisfy({ Motion(rawValue: $0) != nil }) else {
                throw ThemeError.invalid("每个光标必须有常态动画及有效的系统标识。")
            }
            for clip in role.clips.values { try clip.validate() }
        }
    }
}

public enum ThemeError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
