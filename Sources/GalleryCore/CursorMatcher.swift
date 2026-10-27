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
        guard let image = try? CursorImages.bitmap(data), width > 0, height > 0, image.width <= 2048, image.height <= 2048 else { return nil }
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

public struct CursorMatcher {
    private var entries: [CursorFingerprint: Set<String>] = [:]
    private var animatedFrameCounts = Set<Int>()
    public init() {}
    public mutating func addRepresentations(_ dictionary: [String: Any], role: String) {
        for data in dictionary["Representations"] as? [Data] ?? [] {
            var one = dictionary; one["Representations"] = [data]
            if let clip = try? CursorImages.fromCape(one) { add(clip, role: role) }
        }
    }
    public mutating func add(_ clip: CursorClip, role: String) {
        if clip.frames.count > 1 { animatedFrameCounts.insert(clip.sampled().frames.count) }
        for frame in clip.sampled().frames {
            if let sample = CursorFingerprint(data: frame, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY) {
                entries[sample, default: []].insert(role)
            }
        }
    }
    /// WindowServer returns a complete vertical filmstrip for an animated
    /// registered cursor, but its global-data API omits the frame count.
    /// Only try counts present in our registered resources, and require the
    /// first, middle and last frames to agree on the role.
    public func matchCurrent(_ dictionary: [String: Any]) -> [String] {
        if let height = dictionary["PointsHigh"] as? NSNumber, height.doubleValue <= 128,
           let clip = try? CursorImages.fromCape(dictionary) {
            let result = match(clip)
            if !result.isEmpty { return result }
        }
        guard let height = dictionary["PointsHigh"] as? NSNumber,
              let width = dictionary["PointsWide"] as? NSNumber,
              let data = (dictionary["Representations"] as? [Data])?.first,
              let image = try? CursorImages.bitmap(data) else { return [] }
        let hotX = (dictionary["HotSpotX"] as? NSNumber)?.doubleValue ?? 0
        let hotY = (dictionary["HotSpotY"] as? NSNumber)?.doubleValue ?? 0
        for count in animatedFrameCounts.sorted() where height.doubleValue / Double(count) >= 1 && height.doubleValue / Double(count) <= 128 {
            let pointsHigh = height.doubleValue / Double(count)
            guard image.height % count == 0, hotY < pointsHigh else { continue }
            let pixelsHigh = image.height / count
            var candidates: Set<String>?
            for index in Set([0, count / 2, count - 1]) {
                guard let cropped = image.cropping(to: CGRect(x: 0, y: index * pixelsHigh, width: image.width, height: pixelsHigh)),
                      let png = try? CursorImages.png(cropped) else { candidates = []; break }
                let frame = CursorClip(frames: [png], width: width.doubleValue, height: pointsHigh, hotX: hotX, hotY: hotY)
                let found = Set(match(frame))
                candidates = candidates.map { $0.intersection(found) } ?? found
                if candidates?.isEmpty == true { break }
            }
            if let candidates, !candidates.isEmpty { return candidates.sorted() }
        }
        return []
    }
    public func match(_ clip: CursorClip) -> [String] {
        guard let first = clip.frames.first,
              let sample = CursorFingerprint(data: first, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY) else { return [] }
        if let exact = entries[sample] { return exact.sorted() }
        var best = 0.075, matches = Set<String>()
        for (candidate, ids) in entries {
            let distance = sample.distance(to: candidate)
            if distance < best - 0.001 { best = distance; matches = ids }
            else if distance <= best + 0.001 && distance < 0.075 { matches.formUnion(ids) }
        }
        return matches.sorted()
    }
}
