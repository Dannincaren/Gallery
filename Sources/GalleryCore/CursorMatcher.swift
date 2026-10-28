import AppKit

/// A visual fingerprint normalized to the visible bounding box. WindowServer
/// can crop transparent padding and scale a registered image; exact PNG/TIFF
/// hashes are not an appropriate semantic cursor identity.
public struct CursorFingerprint: Hashable {
    let pixels: [UInt8]
    let aspect: Int
    let hotX: Int
    let hotY: Int
    public init?(data: Data, width: Double, height: Double, hotX: Double, hotY: Double) {
        guard let image = try? CursorImages.bitmap(data) else { return nil }
        self.init(image: image, width: width, height: height, hotX: hotX, hotY: hotY)
    }
    public init?(image: CGImage, width: Double, height: Double, hotX: Double, hotY: Double) {
        guard width > 0, height > 0, image.width <= 2048, image.height <= 2048 else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where rgba[(y * w + x) * 4 + 3] > 12 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        var sample: [UInt8] = []; sample.reserveCapacity(24 * 24 * 4)
        for y in 0..<24 { for x in 0..<24 {
            let sx = minX + min(bw - 1, x * bw / 24), sy = minY + min(bh - 1, y * bh / 24)
            let start = (sy * w + sx) * 4
            sample += rgba[start..<start + 4].map { $0 / 16 }
        } }
        pixels = sample
        aspect = Int((log(Double(bw) / Double(bh)) * 1000).rounded())
        self.hotX = Int(((hotX / width * Double(w) - Double(minX)) / Double(bw) * 1000).rounded())
        self.hotY = Int(((hotY / height * Double(h) - Double(minY)) / Double(bh) * 1000).rounded())
    }
    public func distance(to other: CursorFingerprint) -> Double {
        guard abs(aspect - other.aspect) <= 160, abs(hotX - other.hotX) <= 180,
              abs(hotY - other.hotY) <= 180 else { return .infinity }
        return visualDistance(to: other)
    }
    public var geometryDescription: String { "aspect=\(aspect) hotspot=\(hotX),\(hotY)" }
    public func visualDistance(to other: CursorFingerprint) -> Double {
        let error = zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(error) / Double(pixels.count * 15)
    }
}

public struct CursorIdentification: Equatable, Sendable {
    public var roles: [String]
    public var appliedRoles: [String]
    public static let unknown = CursorIdentification(roles: [], appliedRoles: [])
    public init(roles: [String], appliedRoles: [String] = []) { self.roles = roles; self.appliedRoles = appliedRoles }
}

public struct CursorMatcher {
    private struct Entry {
        var roles = Set<String>()
        var applied = Set<String>()
    }
    private var entries: [CursorFingerprint: Entry] = [:]
    private var animatedFrameCounts = Set<Int>()
    public init() {}
    public mutating func addRepresentations(_ dictionary: [String: Any], role: String) {
        for data in dictionary["Representations"] as? [Data] ?? [] {
            var one = dictionary; one["Representations"] = [data]
            if let clip = try? CursorImages.fromCape(one) { add(clip, role: role) }
        }
    }
    public mutating func add(_ clip: CursorClip, role: String, applied: Bool = false) {
        if clip.frames.count > 1 { animatedFrameCounts.insert(clip.sampled().frames.count) }
        for frame in clip.sampled().frames {
            if let sample = CursorFingerprint(data: frame, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY) {
                var entry = entries[sample] ?? Entry()
                entry.roles.insert(role)
                if applied { entry.applied.insert(role) }
                entries[sample] = entry
            }
        }
    }
    private func identify(_ sample: CursorFingerprint) -> CursorIdentification {
        if let exact = entries[sample] { return .init(roles: exact.roles.sorted(), appliedRoles: exact.applied.sorted()) }
        var best = 0.075, roles = Set<String>(), applied = Set<String>()
        for (candidate, entry) in entries {
            guard abs(sample.aspect - candidate.aspect) <= 160,
                  abs(sample.hotX - candidate.hotX) <= 180, abs(sample.hotY - candidate.hotY) <= 180 else { continue }
            let budget = Int((best + 0.001) * Double(sample.pixels.count * 15))
            var error = 0
            for i in sample.pixels.indices {
                error += abs(Int(sample.pixels[i]) - Int(candidate.pixels[i]))
                if error > budget { break }
            }
            guard error <= budget else { continue }
            let distance = Double(error) / Double(sample.pixels.count * 15)
            if distance < best - 0.001 { best = distance; roles = entry.roles; applied = entry.applied }
            else if distance <= best + 0.001 && distance < 0.075 { roles.formUnion(entry.roles); applied.formUnion(entry.applied) }
        }
        return .init(roles: roles.sorted(), appliedRoles: applied.sorted())
    }
    /// Direct bitmap matching keeps PNG conversion entirely out of observation.
    /// Registered animations are vertical filmstrips; validate three frames.
    public func identify(image: CGImage, width: Double, height: Double, hotX: Double, hotY: Double, frameCount: Int = 1) -> CursorIdentification {
        // Global snapshots report physical bitmap dimensions, including 5x /
        // 10x system representations. The theme's 128-point geometry limit
        // must not reject a perfectly valid high-resolution static arrow.
        if frameCount == 1,
           let sample = CursorFingerprint(image: image, width: width, height: height, hotX: hotX, hotY: hotY) {
            let result = identify(sample)
            if !result.roles.isEmpty { return result }
        }
        let counts = frameCount > 1 ? [frameCount] : animatedFrameCounts.sorted()
        for count in counts where count > 1 && image.height % count == 0 {
            let pointsHigh = frameCount > 1 ? height : height / Double(count)
            guard (1...128).contains(pointsHigh), hotY < pointsHigh else { continue }
            let pixelsHigh = image.height / count
            var roles: Set<String>?, applied: Set<String>?
            for index in Set([0, count / 2, count - 1]) {
                guard let cropped = image.cropping(to: CGRect(x: 0, y: index * pixelsHigh, width: image.width, height: pixelsHigh)),
                      let sample = CursorFingerprint(image: cropped, width: width, height: pointsHigh, hotX: hotX, hotY: hotY) else { roles = []; break }
                let found = identify(sample)
                roles = roles.map { $0.intersection(found.roles) } ?? Set(found.roles)
                applied = applied.map { $0.intersection(found.appliedRoles) } ?? Set(found.appliedRoles)
                if roles?.isEmpty == true { break }
            }
            if let roles, !roles.isEmpty { return .init(roles: roles.sorted(), appliedRoles: (applied ?? []).sorted()) }
        }
        return .unknown
    }
    public func matchCurrent(_ dictionary: [String: Any]) -> [String] {
        guard let data = (dictionary["Representations"] as? [Data])?.first, let image = try? CursorImages.bitmap(data),
              let width = dictionary["PointsWide"] as? NSNumber, let height = dictionary["PointsHigh"] as? NSNumber else { return [] }
        return identify(image: image, width: width.doubleValue, height: height.doubleValue,
            hotX: (dictionary["HotSpotX"] as? NSNumber)?.doubleValue ?? 0,
            hotY: (dictionary["HotSpotY"] as? NSNumber)?.doubleValue ?? 0,
            frameCount: (dictionary["FrameCount"] as? NSNumber)?.intValue ?? 1).roles
    }
    public func match(_ clip: CursorClip) -> [String] {
        guard let first = clip.frames.first, let sample = CursorFingerprint(data: first, width: clip.width,
            height: clip.height, hotX: clip.hotX, hotY: clip.hotY) else { return [] }
        return identify(sample).roles
    }
}
