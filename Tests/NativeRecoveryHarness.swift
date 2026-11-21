import AppKit
import GalleryCore

@main struct NativeRecoveryHarness {
    static func check(_ condition: Bool, _ why: String) throws {
        if !condition { throw ThemeError.invalid(why) }
    }
    static func main() throws {
        for count in [1, 2, 24, 30, 72, 240] {
            let context = CGContext(data: nil, width: 12, height: count * 10, bitsPerComponent: 8, bytesPerRow: 48,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for index in 0..<count {
                context.setFillColor(NSColor(srgbRed: Double(index) / 240, green: Double(index % 2), blue: 0.5, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: index * 10, width: 12, height: 10))
            }
            let raw: [String: Any] = ["FrameCount": count, "FrameDuration": 0.01, "PointsWide": 12, "PointsHigh": 10,
                "HotSpotX": 3.0, "HotSpotY": 4.0, "Representations": [try CursorImages.png(context.makeImage()!)]]
            let sampled = try CursorResourceSampling.sampled(raw)
            let source = try CursorImages.fromCape(raw), output = try CursorImages.fromCape(sampled)
            try check(output.frames.count == min(24, count) && abs(source.duration - output.duration) < 1e-7, "Count/cycle changed")
            try check(output.width == source.width && output.height == source.height && output.hotX == 3 && output.hotY == 4, "Recovery geometry changed")
            // Compare the decoded pixels of every selected source frame, not
            // encoded PNG equality (which may choose another color model).
            for index in output.frames.indices {
                var x = raw, y = sampled
                x["FrameCount"] = 1; x["Representations"] = [source.frames[index * count / output.frames.count]]
                y["FrameCount"] = 1; y["Representations"] = [output.frames[index]]
                x["FrameDuration"] = 0.1; y["FrameDuration"] = 0.1
                try check(CursorResourceSampling.equal(x, y), "Sample frame order/pixels changed")
            }
            let journal = try CursorRestoreJournal.encode(cursors: [CursorRestoreJournal.waitID: sampled], originalWait: raw)
            let decoded = try CursorRestoreJournal.decode(journal)
            try check(CursorResourceSampling.equal(decoded.originalWait!, raw) && CursorResourceSampling.equal(decoded.cursors[CursorRestoreJournal.waitID]!, sampled), "Raw original was not retained")
            var wrong = sampled; wrong["HotSpotX"] = 0
            let bad = try CursorRestoreJournal.encode(cursors: [CursorRestoreJournal.waitID: wrong], originalWait: raw)
            do { _ = try CursorRestoreJournal.decode(bad); throw ThemeError.invalid("Mismatched journal accepted") }
            catch { try check(error.localizedDescription != "Mismatched journal accepted", "Mismatched journal accepted") }
            let legacy = try CursorRestoreJournal.encode(cursors: ["com.apple.coregraphics.Arrow": sampled], originalWait: nil)
            let old = try CursorRestoreJournal.decode(legacy)
            try check(old.originalWait == nil && old.cursors.count == 1, "Legacy journal no longer readable")
        }
        print("PASS native sampling for 1/2/24/30/72/240 frames: every pixel/order, cycle, dimensions/hotspot, raw backup, v2 verification and legacy recovery")
        if CommandLine.arguments.count > 2 {
            func read(_ path: String) throws -> [String: Any] { try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any] }
            let raw = try read(CommandLine.arguments[1]), expected = try read(CommandLine.arguments[2])
            try check(CursorResourceSampling.equal(try CursorResourceSampling.sampled(raw), expected), "Product sampler differs from accepted lab restoration")
            print("PASS actual macOS original30 -> native24 matches the user-accepted lab resource, including every representation")
        }
    }
}
