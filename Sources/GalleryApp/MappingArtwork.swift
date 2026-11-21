import AppKit
import GalleryCore

enum MappingPreviewSizing {
    case fit, native, material
    case nativeRow(maxAspect: Double), nativeColumn(maxAspect: Double)
    static func nativeMode(id: String, clips: [String: CursorClip]) -> Self {
        let rows = ["com.apple.cursor.21", "com.apple.cursor.22", "com.apple.cursor.23"]
        let columns = ["com.apple.cursor.17", "com.apple.cursor.18", "com.apple.cursor.19"]
        if rows.contains(id) {
            let aspect = rows.compactMap { clips[$0] }.map { $0.height / $0.width }.max() ?? 1
            return .nativeRow(maxAspect: max(1, aspect))
        }
        if columns.contains(id) {
            let aspect = columns.compactMap { clips[$0] }.map { $0.width / $0.height }.max() ?? 1
            return .nativeColumn(maxAspect: max(1, aspect))
        }
        return .native
    }
    static func size(mode: Self, image: CGSize, available: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let bound = max(0, min(available.width, available.height) - 12)
        let edge: Double
        switch mode {
        case .fit, .material:
            let factor = min(max(0, available.width - 12) / image.width, max(0, available.height - 12) / image.height)
            return CGSize(width: image.width * factor, height: image.height * factor)
        case .native: edge = bound
        case .nativeRow(let aspect):
            let width = bound / aspect
            return CGSize(width: width, height: width * image.height / image.width)
        case .nativeColumn(let aspect):
            let height = bound / aspect
            return CGSize(width: height * image.width / image.height, height: height)
        }
        let factor = edge / max(image.width, image.height)
        return CGSize(width: image.width * factor, height: image.height * factor)
    }
}

struct MappingMaterialAsset: Equatable {
    let id: String
    let clip: CursorClip
}

struct MappingMaterialPresentation {
    let clip: CursorClip
    let appearance: CursorAppearance
    let bounds: CGRect
    let canvas: CGSize
    var factor: Double
    var size: CGSize { CGSize(width: canvas.width * bounds.width * factor, height: canvas.height * bounds.height * factor) }
}

enum MappingScaleGroups {
    /// Compare with the smallest member, never chain through adjacent values.
    static func smaller(_ factors: [String: Double]) -> [String: Double] {
        let sorted = factors.filter { $0.value.isFinite && $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        var result: [String: Double] = [:], anchor = 0.0
        for (id, value) in sorted {
            if anchor == 0 || value > anchor * 1.02 + 1e-9 { anchor = value }
            result[id] = anchor
        }
        return result
    }
}

/// Shared only by one mapping window. Animation cells request the frame they
/// need; decoded rasters and shadow work stay off the main actor and are bounded.
actor MappingFrameCache {
    private struct Key: Hashable { let data: Data; let width: Double; let height: Double; let smooth: Bool; let shadow: Bool }
    private struct CanvasKey: Hashable { let frames: [Data]; let width: Double; let height: Double; let appearance: CursorAppearanceKey }
    private struct CursorAppearanceKey: Hashable {
        let smooth: Bool; let shadow: Bool
        init(_ value: CursorAppearance) { smooth = value.effectiveSmoothEdges; shadow = value.shadow }
    }
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private var canvases: [CanvasKey: CGRect] = [:]
    private var canvasOrder: [CanvasKey] = []
    private var pendingCanvases: [CanvasKey: Task<CGRect?, Never>] = [:]
    func material(_ clip: CursorClip, appearance: CursorAppearance, available: CGSize) async -> MappingMaterialPresentation? {
        guard let bounds = await canvas(clip, appearance: appearance), let first = clip.frames.first else { return nil }
        var still = clip; still.frames = [first]
        var renderer = CursorAppearanceRenderer(appearance)
        guard let rendered = try? renderer.render(still) else { return nil }
        let canvas = CGSize(width: rendered.width, height: rendered.height)
        let factor = min(max(0, available.width - 12) / (canvas.width * bounds.width),
                         max(0, available.height - 12) / (canvas.height * bounds.height))
        return MappingMaterialPresentation(clip: clip, appearance: appearance, bounds: bounds, canvas: canvas, factor: factor)
    }
    func materials(_ assets: [MappingMaterialAsset], appearance: CursorAppearance, available: CGSize) async -> [String: MappingMaterialPresentation] {
        var result: [String: MappingMaterialPresentation] = [:]
        for asset in assets {
            guard !Task.isCancelled else { return [:] }
            result[asset.id] = await material(asset.clip, appearance: appearance, available: available)
        }
        let grouped = MappingScaleGroups.smaller(result.mapValues(\.factor))
        for (id, factor) in grouped { result[id]?.factor = factor }
        return result
    }
    /// One normalized visible union for the entire animation. Frames can use
    /// different pixel resolutions; their shared logical canvas remains stable.
    func canvas(_ clip: CursorClip, appearance: CursorAppearance) async -> CGRect? {
        let key = CanvasKey(frames: clip.frames, width: clip.width, height: clip.height, appearance: CursorAppearanceKey(appearance))
        if let bounds = canvases[key] { return bounds }
        if let pending = pendingCanvases[key] { return await pending.value }
        let pending = Task { await self.computeCanvas(clip, appearance: appearance) }
        pendingCanvases[key] = pending
        let bounds = await pending.value
        pendingCanvases.removeValue(forKey: key)
        if let bounds, !pending.isCancelled {
            if canvasOrder.count >= 80 { canvases.removeValue(forKey: canvasOrder.removeFirst()) }
            canvases[key] = bounds; canvasOrder.append(key)
        }
        return bounds
    }
    private func computeCanvas(_ clip: CursorClip, appearance: CursorAppearance) async -> CGRect? {
        var union = CGRect.null
        for (index, data) in clip.frames.enumerated() {
            guard !Task.isCancelled else { return nil }
            if let raster = image(data, clip: clip, appearance: appearance), let bounds = MappingVisiblePixels.bounds(raster) {
                union = union.union(CGRect(x: bounds.minX / Double(raster.width), y: bounds.minY / Double(raster.height),
                    width: bounds.width / Double(raster.width), height: bounds.height / Double(raster.height)))
            }
            if index % 8 == 7 { await Task.yield() }
        }
        guard !union.isNull else { return nil }
        return union.insetBy(dx: -0.01, dy: -0.01).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    func image(_ data: Data, clip: CursorClip, appearance: CursorAppearance) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = Key(data: data, width: clip.width, height: clip.height, smooth: appearance.effectiveSmoothEdges, shadow: appearance.shadow)
        if let image = images[key] {
            order.removeAll { $0 == key }; order.append(key); return image
        }
        return autoreleasepool {
            var single = clip; single.frames = [data]
            var renderer = CursorAppearanceRenderer(appearance)
            guard let rendered = try? renderer.render(single), let png = rendered.frames.first,
                  let original = try? CursorImages.bitmap(png) else { return nil }
            let raster: CGImage
            if max(original.width, original.height) > 256 {
                let factor = 256.0 / Double(max(original.width, original.height))
                let width = max(1, Int((Double(original.width) * factor).rounded()))
                let height = max(1, Int((Double(original.height) * factor).rounded()))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.interpolationQuality = appearance.effectiveSmoothEdges ? .high : .none
                context.setShouldAntialias(appearance.effectiveSmoothEdges)
                context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let image = context.makeImage() else { return nil }; raster = image
            } else { raster = original }
            guard !Task.isCancelled else { return nil }
            let cost = raster.bytesPerRow * raster.height
            while !order.isEmpty && (order.count >= 128 || bytes + cost > 24 * 1024 * 1024) {
                let oldest = order.removeFirst()
                if let removed = images.removeValue(forKey: oldest) { bytes -= removed.bytesPerRow * removed.height }
            }
            images[key] = raster; order.append(key); bytes += cost
            return raster
        }
    }
    func clear() {
        pendingCanvases.values.forEach { $0.cancel() }; pendingCanvases.removeAll()
        canvases.removeAll(); canvasOrder.removeAll(); images.removeAll(); order.removeAll(); bytes = 0
    }
    func footprint() -> (count: Int, bytes: Int) { (images.count, bytes) }
}

enum NativeMappingArtwork {
    private struct Archive: Codable {
        let schemaVersion: Int
        let sourceSystem: String
        let clips: [String: CursorClip]
    }
    private static let resources = URL(fileURLWithPath: "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors")
    // Only immutable OS files and bundled reference art are sources. Never
    // capture current registrations, NSCursor accessors or recovery journals.
    private static let bundled = Task.detached(priority: .utility) {
        let fallback = Bundle.main.url(forResource: "NativeCursorPreviews", withExtension: "plist")
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Gallery")
            .appendingPathComponent("NativeCursorPreviews-v2.plist")
        return build(fallback: fallback, resources: resources, cache: cache)
    }
    static func prewarm() { _ = bundled }
    static func load() async -> [String: CursorClip] { await bundled.value }
    static func load(from url: URL?) async -> [String: CursorClip] {
        await Task.detached(priority: .utility) { build(fallback: url, resources: resources, cache: nil) }.value
    }
    static func load(fallback: URL?, resources: URL, cache: URL, system: String) async -> [String: CursorClip] {
        await Task.detached(priority: .utility) { build(fallback: fallback, resources: resources, cache: cache, system: system) }.value
    }
    private static func read(_ url: URL?) -> Archive? {
        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1024 * 1024, let data = try? Data(contentsOf: url),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
              Set(archive.clips.keys) == Set(ThemeMapping.nativeRoles.map(\.id)),
              archive.clips.values.allSatisfy({ clip in
                  (try? clip.validate()) != nil && clip.frames.allSatisfy { data in
                      guard let image = try? CursorImages.bitmap(data) else { return false }
                      return max(image.width, image.height) <= 192
                  }
              }) else { return nil }
        return archive
    }
    private static func build(fallback url: URL?, resources: URL, cache: URL?, system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> [String: CursorClip] {
        guard let fallback = read(url), fallback.schemaVersion == 1 else { return [:] }
        // Bump this recipe on source/raster changes; an OS update also rebuilds.
        let identity = "v2:192:" + system + ":" + fallback.sourceSystem
        if let cached = read(cache), cached.schemaVersion == 2, cached.sourceSystem == identity { return cached.clips }
        var clips = fallback.clips
        for descriptor in ThemeMapping.nativeRoles where !descriptor.resource.isEmpty {
            if let clip = vector(named: descriptor.resource, resources: resources) { clips[descriptor.id] = clip }
        }
        if let cache {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            if let data = try? encoder.encode(Archive(schemaVersion: 2, sourceSystem: identity, clips: clips)) {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
        }
        return clips
    }
    private static func vector(named name: String, resources: URL) -> CursorClip? {
        autoreleasepool {
            let current = resources.appendingPathComponent("macos\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)").appendingPathComponent(name)
            let folder = FileManager.default.fileExists(atPath: current.appendingPathComponent("cursor.pdf").path) ? current : resources.appendingPathComponent(name)
            guard let document = CGPDFDocument(folder.appendingPathComponent("cursor.pdf") as CFURL),
                  let page = document.page(at: 1) else { return nil }
            let info = (try? Data(contentsOf: folder.appendingPathComponent("info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            let count = min(240, max(1, (info["frames"] as? NSNumber)?.intValue ?? document.numberOfPages))
            let box = page.getBoxRect(.mediaBox)
            let strip = document.numberOfPages == 1 && count > 1 && box.height >= box.width * Double(count) * 0.75
            let frameHeight = strip ? box.height / Double(count) : box.height
            guard box.width > 0, frameHeight > 0, box.width <= 512, frameHeight <= 512 else { return nil }
            var frames: [Data] = []
            for index in 0..<count {
                let scale = 512 / max(box.width, frameHeight)
                guard let selected = document.page(at: min(document.numberOfPages, index + 1)),
                      let context = CGContext(data: nil, width: max(1, Int((box.width * scale).rounded())), height: max(1, Int((frameHeight * scale).rounded())), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY - (strip ? box.height - Double(index + 1) * frameHeight : 0))
                context.drawPDFPage(selected)
                guard let image = context.makeImage(), let png = try? CursorImages.png(image) else { return nil }; frames.append(png)
            }
            let clip = CursorClip(frames: frames, frameDuration: max(1.0 / 60, (info["delay"] as? NSNumber)?.doubleValue ?? 0.1),
                width: min(128, box.width), height: min(128, frameHeight),
                hotX: min(box.width.nextDown, max(0, (info["hotx"] as? NSNumber)?.doubleValue ?? 0)),
                hotY: min(frameHeight.nextDown, max(0, (info["hoty"] as? NSNumber)?.doubleValue ?? 0)))
            guard var result = centered(clip) else { return nil }
            result.frames = (try? result.frames.map { data in
                let image = try CursorImages.bitmap(data)
                let factor = min(1, 192.0 / Double(max(image.width, image.height)))
                guard factor < 1 else { return data }
                let w = Int((Double(image.width) * factor).rounded()), h = Int((Double(image.height) * factor).rounded())
                let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return try CursorImages.png(context.makeImage()!)
            }) ?? []
            return (try? result.validate()) != nil ? result : nil
        }
    }

    /// Preview-only canvas. Crop every frame to the SAME visible union, keeping
    /// the cursor's motion stable rather than recentering each frame separately.
    /// Source theme clips and live cursor hotspots never pass through here.
    static func centered(_ original: CursorClip) -> CursorClip? {
        autoreleasepool {
            guard !Task.isCancelled, let images = try? original.frames.map(CursorImages.bitmap),
                  let first = images.first, first.width <= 2048, first.height <= 2048,
                  images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { return nil }
            var bounds = CGRect.null
            for image in images {
                guard !Task.isCancelled else { return nil }
                if let rect = MappingVisiblePixels.bounds(image) { bounds = bounds.union(rect) }
            }
            guard !bounds.isNull else { return nil }
            bounds = bounds.integral
            let factor = min(1, 256 / (max(bounds.width, bounds.height) + 4))
            let width = max(1, Int(((bounds.width + 4) * factor).rounded()))
            let height = max(1, Int(((bounds.height + 4) * factor).rounded()))
            var frames: [Data] = []
            for image in images {
                guard let cropped = image.cropping(to: bounds),
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.interpolationQuality = .high
                context.draw(cropped, in: CGRect(x: 2 * factor, y: 2 * factor,
                    width: Double(width) - 4 * factor, height: Double(height) - 4 * factor))
                guard let result = context.makeImage(), let data = try? CursorImages.png(result) else { return nil }
                frames.append(data)
            }
            var clip = original; clip.frames = frames
            clip.width = min(128, max(1, original.width * (bounds.width + 4) / Double(first.width)))
            clip.height = min(128, max(1, original.height * (bounds.height + 4) / Double(first.height)))
            clip.hotX = min(clip.width.nextDown, max(0, original.hotX - (bounds.minX - 2) * original.width / Double(first.width)))
            clip.hotY = min(clip.height.nextDown, max(0, original.hotY - (bounds.minY - 2) * original.height / Double(first.height)))
            return clip
        }
    }
}

enum MappingVisiblePixels {
    static func bounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            let rgba = buffer.bindMemory(to: UInt8.self)
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            // Bitmap row order already matches CGImage's crop coordinates.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height { for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX >= minX && maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }
}
