import AppKit

/// Stored with a theme; source artwork and application-owned cursors stay intact.
public struct CursorAppearance: Codable, Equatable, Sendable {
    public var smoothEdges = true
    public var shadow = false
    public init(smoothEdges: Bool = true, shadow: Bool = false) {
        self.smoothEdges = smoothEdges; self.shadow = shadow
    }
}

/// Bake a soft shadow once when preparing a theme, never on mouse movement.
/// Identical frames shared by aliases and animation phases reuse one bitmap.
public struct CursorAppearanceRenderer {
    private struct Key: Hashable { let data: Data; let width: Double; let height: Double }
    private var frames: [Key: Data] = [:]
    public let appearance: CursorAppearance
    public init(_ appearance: CursorAppearance) { self.appearance = appearance }
    public mutating func render(_ original: CursorClip) throws -> CursorClip {
        guard appearance.shadow else { return original }
        try original.validate()
        let padding = 4.0
        let factor = min(1, (128 - padding * 2) / max(original.width, original.height))
        var clip = original
        clip.width = original.width * factor + padding * 2; clip.height = original.height * factor + padding * 2
        clip.hotX = original.hotX * factor + padding; clip.hotY = original.hotY * factor + padding
        clip.frames = try original.frames.map { data in
            let key = Key(data: data, width: original.width, height: original.height)
            if let cached = frames[key] { return cached }
            let image = try CursorImages.bitmap(data), scale = 3.0
            let width = Int((clip.width * scale).rounded()), height = Int((clip.height * scale).rounded())
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ThemeError.invalid("无法创建光标阴影。") }
            context.interpolationQuality = appearance.smoothEdges ? .high : .none
            context.setShouldAntialias(appearance.smoothEdges)
            context.setShadow(offset: CGSize(width: 0, height: -scale), blur: 1.5 * scale,
                              color: CGColor(gray: 0, alpha: 0.32))
            context.draw(image, in: CGRect(x: padding * scale, y: padding * scale,
                width: original.width * factor * scale, height: original.height * factor * scale))
            guard let rendered = context.makeImage() else { throw ThemeError.invalid("无法创建光标阴影。") }
            let png = try CursorImages.png(rendered); frames[key] = png; return png
        }
        try clip.validate(); return clip
    }
}
