import AppKit
import CryptoKit

public enum CursorImages {
    public static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ThemeError.invalid(L("无法编码图像。"))
        }
        return data
    }
    public static func bitmap(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ThemeError.invalid(L("图像无法解码或像素过大。"))
        }
        return image
    }
    public static func fromCape(_ dictionary: [String: Any]) throws -> CursorClip {
        guard let reps = dictionary["Representations"] as? [Data], !reps.isEmpty,
              let count = dictionary["FrameCount"] as? NSNumber, (1...240).contains(count.intValue),
              let width = dictionary["PointsWide"] as? NSNumber,
              let height = dictionary["PointsHigh"] as? NSNumber else {
            throw ThemeError.invalid(L("光标缺少有效图像、尺寸或帧数。"))
        }
        // Keep the highest resolution representation. Logical points preserve
        // the display size and hotspot on both Retina and non-Retina displays.
        let candidates = try reps.map { try bitmap($0) }
        guard let image = candidates.max(by: { $0.width < $1.width }), image.height % count.intValue == 0 else {
            throw ThemeError.invalid(L("动画条带高度必须是帧数的整数倍。"))
        }
        let frameHeight = image.height / count.intValue
        let frames = try (0..<count.intValue).map { index -> Data in
            guard let frame = image.cropping(to: CGRect(x: 0, y: index * frameHeight, width: image.width, height: frameHeight)) else {
                throw ThemeError.invalid(L("动画裁切失败。"))
            }
            return try png(frame)
        }
        let clip = CursorClip(frames: frames,
                              frameDuration: (dictionary["FrameDuration"] as? NSNumber)?.doubleValue ?? 0.1,
                              width: width.doubleValue, height: height.doubleValue,
                              hotX: (dictionary["HotSpotX"] as? NSNumber)?.doubleValue ?? 0,
                              hotY: (dictionary["HotSpotY"] as? NSNumber)?.doubleValue ?? 0)
        try clip.validate()
        return clip
    }
    public static func capeDictionary(_ original: CursorClip, smoothEdges: Bool = true) throws -> [String: Any] {
        try original.validate()
        let clip = original.sampled()
        let images = try clip.frames.map { try bitmap($0) }
        let representations = try rasters(images, width: clip.width, height: clip.height, smoothEdges: smoothEdges).map(png)
        return ["FrameCount": images.count, "FrameDuration": clip.frameDuration,
                "PointsWide": clip.width, "PointsHigh": clip.height,
                "HotSpotX": clip.hotX, "HotSpotY": clip.hotY, "Representations": representations]
    }
    /// The same point grid and frame order for file export and live resources.
    /// Live playback can pass these bitmaps straight to WindowServer, without
    /// encoding PNG and immediately decoding it again on the input callback.
    public static func rasters(_ images: [CGImage], width: Double, height: Double,
                               smoothEdges: Bool = true, maximumScale: Int = 3) throws -> [CGImage] {
        guard (1...24).contains(images.count), width.isFinite, height.isFinite,
              (1...128).contains(width), (1...128).contains(height), (1...3).contains(maximumScale) else {
            throw ThemeError.invalid(L("光标图像、大小或分辨率超出有效范围。"))
        }
        return try (1...maximumScale).map { scale in
            let pixelsWide = max(1, Int((width * Double(scale)).rounded()))
            let pixelsHigh = max(1, Int((height * Double(scale)).rounded()))
            guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh * images.count,
                bitsPerComponent: 8, bytesPerRow: pixelsWide * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ThemeError.invalid(L("无法创建动画条带。"))
            }
            context.interpolationQuality = smoothEdges ? .high : .none
            context.setShouldAntialias(smoothEdges)
            for (index, image) in images.enumerated() {
                context.draw(image, in: CGRect(x: 0, y: (images.count - index - 1) * pixelsHigh, width: pixelsWide, height: pixelsHigh))
            }
            guard let strip = context.makeImage() else { throw ThemeError.invalid(L("无法创建动画条带。")) }
            return strip
        }
    }
    /// Match the bitmap AND hotspot. No semantic guessing from a position, AX
    /// role or foreground app; unknown/custom application cursors are skipped.
    public static func signature(_ data: Data, hotX: Double, hotY: Double, width: Double, height: Double) -> String? {
        guard let image = try? bitmap(data), width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                          bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard success else { return nil }
        let hash = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        return "\(hash):\(Int((hotX / width * 100).rounded())):\(Int((hotY / height * 100).rounded()))"
    }
}

public enum ThemeFiles {
    public static func load(_ url: URL, legacyPointerScale: Double = 1) throws -> GalleryTheme {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 80_000_000 else { throw ThemeError.invalid(L("主题文件超过 80 MB。")) }
        let data = try Data(contentsOf: url)
        var theme: GalleryTheme
        if url.pathExtension.lowercased() == "cape" {
            guard let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let cursors = p["Cursors"] as? [String: [String: Any]] else {
                throw ThemeError.invalid(L("无法读取 Mousecape 主题。"))
            }
            let roles = try cursors.keys.sorted().map { key in
                CursorRole(id: key, name: roleName(key), clips: [Motion.normal.rawValue: try CursorImages.fromCape(cursors[key]!)])
            }
            theme = GalleryTheme(name: p["CapeName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                 author: p["Author"] as? String ?? "", roles: roles)
        } else {
            struct Header: Decodable { var formatVersion: Int; var pointerScale: Double? }
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.formatVersion == 2 {
                theme = try JSONDecoder().decode(ThemeArchive.self, from: data).theme()
            } else { theme = try JSONDecoder().decode(GalleryTheme.self, from: data) }
            // Only existing library files opt into the old application setting.
            // External imports use 100% unless their archive specifies a size.
            if header.pointerScale == nil { theme.pointerScale = legacyPointerScale }
        }
        try theme.validate()
        // Validate image data at the import boundary, before a native call.
        var checked = Set<Data>()
        if let cover = theme.coverFrame { _ = try CursorImages.bitmap(cover); checked.insert(cover) }
        for role in theme.roles {
            let clips = Array(role.clips.values) + role.variants.values.flatMap { $0.map(\.clip) }
            for clip in clips { for frame in clip.frames where checked.insert(frame).inserted { _ = try CursorImages.bitmap(frame) } }
        }
        return theme
    }
    public static func save(_ theme: GalleryTheme, to url: URL) throws {
        try theme.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ThemeArchive(theme)).write(to: url, options: .atomic)
    }
    public static func exportCape(_ theme: GalleryTheme, to url: URL) throws {
        try theme.validate()
        let selected = theme.roles.filter { !$0.usesNative && !CursorCatalog.assetOnly($0.id) }
        guard !selected.isEmpty else { throw ThemeError.invalid(L("没有需要导出的自定义光标。完整设置请保存为 Gallery 主题。")) }
        var appearance = CursorAppearanceRenderer(theme.appearance)
        let cursors = try Dictionary(uniqueKeysWithValues: selected.map { role in
            (role.id, try CursorImages.capeDictionary(appearance.render(role.clip(.normal)!).scaled(by: theme.pointerScale * role.scale),
                                                   smoothEdges: theme.appearance.smoothEdges))
        })
        let dictionary: [String: Any] = ["CapeName": theme.name, "Author": theme.author,
            "Identifier": "local.gallery.export", "CapeVersion": 1.0, "Version": 2.0,
            "MinimumVersion": 2.0, "HiDPI": true, "Cloud": false, "Cursors": cursors]
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url, options: .atomic)
    }
    public static func roleName(_ id: String) -> String {
        CursorCatalog.title(id)
    }
}
