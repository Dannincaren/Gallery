import Foundation

public enum Motion: String, Codable, CaseIterable, Identifiable, Sendable {
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

public struct CursorClip: Codable, Equatable, Sendable {
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
    /// Use one point/pixel grid for both registered resources and AppKit.
    /// WindowServer truncates fractional cursor hotspots while AppKit can
    /// round them. Keep that conversion at the display boundary; imported
    /// artwork and the editor's precise geometry remain unchanged.
    public func alignedToPixels() -> CursorClip {
        var result = self
        result.width = max(1, width.rounded()); result.height = max(1, height.rounded())
        result.hotX = min(result.width - 1, max(0, (hotX * result.width / width).rounded()))
        result.hotY = min(result.height - 1, max(0, (hotY * result.height / height).rounded()))
        return result
    }
    @discardableResult
    public mutating func duplicateFrame(at index: Int) throws -> Int {
        guard frames.indices.contains(index), frames.count < 240 else { throw ThemeError.invalid("无法复制这一帧：最多支持 240 帧。") }
        frames.insert(frames[index], at: index + 1)
        return index + 1
    }
}

public struct CursorVariant: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var clip: CursorClip
    public init(id: String, name: String, clip: CursorClip) { self.id = id; self.name = name; self.clip = clip }
}

public struct CursorRole: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var clips: [String: CursorClip]
    /// Presence of a hold clip is the interaction policy. Old serialized
    /// switches are accepted on import but no longer override the assets.
    public var splitClickAnimation: Bool { clip(.hold) != nil }
    public var scale: Double
    public var usesNative: Bool
    public var sourceThemeName: String?
    public var idleDelayOverride: Double?
    /// Alternatives are assets, not simultaneously running animations.
    public var variants: [String: [CursorVariant]]
    public var selectedVariants: [String: String]
    public init(id: String, name: String, clips: [String: CursorClip], splitClickAnimation: Bool? = nil,
                scale: Double = 1, usesNative: Bool = false, sourceThemeName: String? = nil, idleDelayOverride: Double? = nil,
                variants: [String: [CursorVariant]] = [:], selectedVariants: [String: String] = [:]) {
        self.id = id; self.name = name; self.clips = clips
        self.scale = scale; self.usesNative = usesNative; self.sourceThemeName = sourceThemeName
        self.idleDelayOverride = idleDelayOverride
        self.variants = variants; self.selectedVariants = selectedVariants
    }
    private enum CodingKeys: String, CodingKey { case id, name, clips, splitClickAnimation, scale, usesNative, sourceThemeName, idleDelayOverride, variants, selectedVariants }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decode([String: CursorClip].self, forKey: .clips)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        usesNative = try c.decodeIfPresent(Bool.self, forKey: .usesNative) ?? false
        sourceThemeName = try c.decodeIfPresent(String.self, forKey: .sourceThemeName)
        idleDelayOverride = try c.decodeIfPresent(Double.self, forKey: .idleDelayOverride)
        variants = try c.decodeIfPresent([String: [CursorVariant]].self, forKey: .variants) ?? [:]
        selectedVariants = try c.decodeIfPresent([String: String].self, forKey: .selectedVariants) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(clips, forKey: .clips)
        // Keep the legacy key so older readers can still import new themes.
        try c.encode(splitClickAnimation, forKey: .splitClickAnimation)
        try c.encode(scale, forKey: .scale); try c.encode(usesNative, forKey: .usesNative)
        try c.encodeIfPresent(sourceThemeName, forKey: .sourceThemeName)
        try c.encodeIfPresent(idleDelayOverride, forKey: .idleDelayOverride)
        if !variants.isEmpty { try c.encode(variants, forKey: .variants) }
        if !selectedVariants.isEmpty { try c.encode(selectedVariants, forKey: .selectedVariants) }
    }
    public func clip(_ motion: Motion) -> CursorClip? { clips[motion.rawValue] }
    public func idleDelay(default global: Double) -> Double { idleDelayOverride ?? global }
    public mutating func selectVariant(_ id: String, for motion: Motion) {
        let key = motion.rawValue
        guard selectedVariants[key] != id else { return }
        guard let variant = variants[key]?.first(where: { $0.id == id }) else { return }
        // Keep edits to the outgoing choice, including clips from old themes.
        if let current = clips[key] {
            if let oldID = selectedVariants[key], let index = variants[key]?.firstIndex(where: { $0.id == oldID }) {
                variants[key]?[index].clip = current
            } else if current != variant.clip {
                let saved = CursorVariant(id: UUID().uuidString, name: "原有素材", clip: current)
                variants[key, default: []].append(saved)
            }
        }
        clips[key] = variant.clip; selectedVariants[key] = id
    }
}

public struct GalleryTheme: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var name: String
    public var author: String
    public var roles: [CursorRole]
    /// Multiplies each role's size, independently for this theme.
    public var pointerScale: Double = 1
    public var appearance = CursorAppearance()
    /// A static cover snapshot, independent of animation editing and playback.
    public var coverFrame: Data?
    public var idleDelay: Double = 8
    public var idleEnabled = true
    public var clickEnabled = true
    public var excludedBundleIDs: [String] = []
    public init(name: String, author: String = "", roles: [CursorRole]) {
        self.name = name; self.author = author; self.roles = roles
    }
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, author, roles, pointerScale, appearance, coverFrame, idleDelay, idleEnabled, clickEnabled, excludedBundleIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decode(String.self, forKey: .author)
        roles = try c.decode([CursorRole].self, forKey: .roles)
        pointerScale = try c.decodeIfPresent(Double.self, forKey: .pointerScale) ?? 1
        appearance = try c.decodeIfPresent(CursorAppearance.self, forKey: .appearance) ?? CursorAppearance()
        coverFrame = try c.decodeIfPresent(Data.self, forKey: .coverFrame)
        idleDelay = try c.decode(Double.self, forKey: .idleDelay)
        idleEnabled = try c.decode(Bool.self, forKey: .idleEnabled)
        clickEnabled = try c.decode(Bool.self, forKey: .clickEnabled)
        excludedBundleIDs = try c.decode([String].self, forKey: .excludedBundleIDs)
    }
    public func validate() throws {
        guard formatVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !roles.isEmpty, roles.count <= 80, Set(roles.map(\.id)).count == roles.count,
              idleDelay.isFinite, (1...600).contains(idleDelay), pointerScale.isFinite, (0.25...3).contains(pointerScale) else {
            throw ThemeError.invalid("主题格式、角色或待机时间无效。")
        }
        if let coverFrame, coverFrame.isEmpty || coverFrame.count > 8_000_000 { throw ThemeError.invalid("主题封面图像无效或过大。") }
        for role in roles {
            if let delay = role.idleDelayOverride, !delay.isFinite || !(1...600).contains(delay) {
                throw ThemeError.invalid("角色待机等待时间应为 1–600 秒。")
            }
            guard role.id.hasPrefix("com.apple."), role.clip(.normal) != nil, role.scale.isFinite, (0.25...3).contains(role.scale),
                  role.clips.keys.allSatisfy({ Motion(rawValue: $0) != nil }) else {
                throw ThemeError.invalid("每个光标必须有常态动画及有效的系统标识。")
            }
            for clip in role.clips.values { try clip.validate() }
            guard role.variants.count <= Motion.allCases.count, role.variants.allSatisfy({ Motion(rawValue: $0.key) != nil && $0.value.count <= 32 }),
                  role.selectedVariants.allSatisfy({ motion, id in role.variants[motion]?.contains(where: { $0.id == id }) == true }) else {
                throw ThemeError.invalid("素材选项或所选版本无效。")
            }
            for variants in role.variants.values {
                guard Set(variants.map(\.id)).count == variants.count else { throw ThemeError.invalid("素材版本标识重复。") }
                for variant in variants { try variant.clip.validate() }
            }
        }
    }
}

public enum ThemeError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
