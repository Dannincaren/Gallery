import AppKit

/// Samples raw registration strips without resizing, cropping or discarding
/// representations. Preview artwork must never be passed to this recovery path.
public enum CursorResourceSampling {
    public static func sampled(_ original: [String: Any], limit: Int = 24) throws -> [String: Any] {
        _ = try CursorImages.fromCape(original)
        guard let count = (original["FrameCount"] as? NSNumber)?.intValue,
              let duration = (original["FrameDuration"] as? NSNumber)?.doubleValue,
              duration.isFinite, duration > 0, (1...24).contains(limit),
              let reps = original["Representations"] as? [Data], !reps.isEmpty else {
            throw ThemeError.invalid("Invalid native cursor resource")
        }
        guard count > limit else { return original }
        let result: [Data] = try reps.map { data in
            let image = try CursorImages.bitmap(data), row = image.bytesPerRow
            guard image.height % count == 0, let provider = image.dataProvider,
                  let bytes = provider.data, CFDataGetLength(bytes) >= row * image.height,
                  let source = CFDataGetBytePtr(bytes), let space = image.colorSpace else {
                throw ThemeError.invalid("Invalid native cursor strip")
            }
            let height = image.height / count
            var sampled = Data(count: row * height * limit)
            sampled.withUnsafeMutableBytes { output in
                for index in 0..<limit {
                    memcpy(output.baseAddress!.advanced(by: index * height * row),
                           source.advanced(by: (index * count / limit) * height * row), height * row)
                }
            }
            guard let output = CGDataProvider(data: sampled as CFData),
                  let strip = CGImage(width: image.width, height: height * limit,
                    bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                    bytesPerRow: row, space: space, bitmapInfo: image.bitmapInfo, provider: output,
                    decode: nil, shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
                throw ThemeError.invalid("Could not sample native cursor strip")
            }
            return try CursorImages.png(strip)
        }
        var resource = original
        resource["Representations"] = result; resource["FrameCount"] = limit
        resource["FrameDuration"] = duration * Double(count) / Double(limit)
        return resource
    }
    public static func equal(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        for key in ["FrameCount", "FrameDuration", "PointsWide", "PointsHigh", "HotSpotX", "HotSpotY"] {
            guard let x = (a[key] as? NSNumber)?.doubleValue, let y = (b[key] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite, abs(x - y) < 1e-7 else { return false }
        }
        guard let xs = a["Representations"] as? [Data], let ys = b["Representations"] as? [Data],
              xs.count == ys.count, !xs.isEmpty else { return false }
        return zip(xs, ys).allSatisfy { x, y in
            guard let lhs = try? CursorImages.bitmap(x), let rhs = try? CursorImages.bitmap(y),
                  lhs.width == rhs.width, lhs.height == rhs.height else { return false }
            guard let x = pixels(lhs), let y = pixels(rhs) else { return false }
            return x == y
        }
    }
    private static func pixels(_ image: CGImage) -> Data? {
        var data = Data(count: image.width * image.height * 4)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        return success ? data : nil
    }
}

/// v2 keeps the complete pre-activation Wait resource alongside its explicitly
/// sampled restoration. Old non-Wait journals remain readable.
public enum CursorRestoreJournal {
    public static let waitID = "com.apple.coregraphics.Wait"
    public static func encode(cursors: [String: [String: Any]], originalWait: [String: Any]?) throws -> Data {
        var property: [String: Any] = cursors
        if let originalWait {
            property = ["GalleryRecoveryVersion": 2, "Cursors": cursors, "OriginalWait": originalWait]
        }
        return try PropertyListSerialization.data(fromPropertyList: property, format: .binary, options: 0)
    }
    public static func decode(_ data: Data) throws -> (cursors: [String: [String: Any]], originalWait: [String: Any]?) {
        guard data.count <= 16 * 1024 * 1024,
              let property = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ThemeError.invalid("Invalid recovery journal")
        }
        let cursors: [String: [String: Any]], raw: [String: Any]?
        if property["GalleryRecoveryVersion"] != nil {
            guard (property["GalleryRecoveryVersion"] as? NSNumber)?.intValue == 2,
                  let values = property["Cursors"] as? [String: [String: Any]],
                  let original = property["OriginalWait"] as? [String: Any],
                  let restore = values[waitID], CursorResourceSampling.equal(try CursorResourceSampling.sampled(original), restore) else {
                throw ThemeError.invalid("Invalid native Wait recovery journal")
            }
            cursors = values; raw = original
        } else { cursors = property as? [String: [String: Any]] ?? [:]; raw = nil }
        guard !cursors.isEmpty else { throw ThemeError.invalid("Empty recovery journal") }
        for (id, value) in cursors {
            guard !id.isEmpty, (try CursorImages.fromCape(value)).frames.count <= 24 else { throw ThemeError.invalid("Invalid recovery resource") }
        }
        return (cursors, raw)
    }
}
