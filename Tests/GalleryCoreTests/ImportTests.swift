import AppKit
import GalleryCore

final class ImportTests {
    func frame(_ color: NSColor) throws -> Data {
        let context = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 48,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        return try CursorImages.png(context.makeImage()!)
    }
    func testCapeRoundTripPreservesOrderHotspotsAndSize() throws {
        let first = try frame(.red), last = try frame(.blue)
        let original = CursorClip(frames: [first, last], frameDuration: 0.13, width: 24, height: 24, hotX: 3.5, hotY: 6)
        let dictionary = try CursorImages.capeDictionary(original)
        let representations = dictionary["Representations"] as! [Data]
        expectEqual(try representations.map { try CursorImages.bitmap($0).width }, [24, 48, 72])
        let restored = try CursorImages.fromCape(dictionary)
        expectEqual(restored.frameDuration, 0.13)
        expectEqual(restored.hotX, 3.5)
        expectEqual(restored.hotY, 6)
        expectEqual(restored.width, 24)
        for (a, b) in zip(original.frames, restored.frames) {
            expectEqual(CursorImages.signature(a, hotX: 0, hotY: 0, width: 24, height: 24),
                           CursorImages.signature(b, hotX: 0, hotY: 0, width: 24, height: 24))
        }
    }
    func testResamplingPreservesDuration() {
        let original = CursorClip(frames: (0..<100).map { Data([$0]) }, frameDuration: 0.02)
        let sampled = original.sampled()
        expectEqual(sampled.frames.count, 24)
        expectEqual(sampled.duration, original.duration, accuracy: 0.000001)
        expectEqual(sampled.frames.first, original.frames.first)
    }
    func testRejectsInvalidGeometryAndNonFiniteTiming() {
        var clip = CursorClip(frames: [Data([1])], width: 32, height: 32, hotX: 32)
        expectThrows(try clip.validate())
        clip.hotX = 0; clip.frameDuration = .nan
        expectThrows(try clip.validate())
    }
    func testDuplicateRolesAndMalformedPEAreRejected() throws {
        let clip = CursorClip(frames: [try frame(.red)])
        let role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": clip])
        expectThrows(try GalleryTheme(name: "Duplicate", roles: [role, role]).validate())
        for count in [0, 2, 64, 128] { expectThrows(try WindowsResources(data: Data(repeating: 0, count: count))) }
    }
    func testCURHotspotAndPixels() throws {
        let png = try frame(.red)
        var data = Data([0, 0, 2, 0, 1, 0, 12, 12, 0, 0, 3, 0, 4, 0])
        func append(_ n: Int) { data.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        append(png.count); append(22); data.append(png)
        let result = try AnimationImport.read(data, extension: "cur")
        expectEqual(result.hotX, 3); expectEqual(result.hotY, 4)
        expectEqual(result.width, 12)
        expectEqual(result.frames.count, 1)
        data[18] = 255
        expectThrows(try AnimationImport.read(data, extension: "cur"))
    }
    func testCURDIBAlphaAndBottomUpOrder() throws {
        var payload = Data()
        func number(_ n: Int, _ size: Int = 4) { payload.append(contentsOf: (0..<size).map { UInt8((n >> ($0 * 8)) & 255) }) }
        number(40); number(2); number(4); number(1, 2); number(32, 2)
        number(0); number(16); number(0); number(0); number(0); number(0)
        // bottom row blue, top row red; explicit alpha, no AND mask needed.
        payload.append(contentsOf: [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255])
        var cur = Data([0, 0, 2, 0, 1, 0, 2, 2, 0, 0, 0, 0, 0, 0])
        for n in [payload.count, 22] { cur.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        cur.append(payload)
        let clip = try AnimationImport.read(cur, extension: "cur")
        let rep = NSBitmapImageRep(data: clip.frames[0])!
        let top = rep.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        let bottom = rep.colorAt(x: 0, y: 1)!.usingColorSpace(.deviceRGB)!
        expectGreater(top.redComponent, 0.9)
        expectGreater(bottom.blueComponent, 0.9)
        expectGreater(top.alphaComponent, 0.9)
    }
    func testRealPRTSOptionalIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["GALLERY_PRTS_EXE"] else {
            return
        }
        let resources = try WindowsResources(data: Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
        expectGreater(resources.entries.count, 100)
        expectNotNil(resources.resource(suffix: "normal_press.ani"))
        let theme = try resources.theme()
        try theme.validate()
        expectGreater(theme.roles.count, 40)
        for name in ["正常选择", "帮助选择", "链接选择", "后台运行", "忙", "精准选择", "手写", "移动", "候选选择", "垂直调整", "水平调整", "对角调整 ↗↙", "对角调整 ↖↘", "不可用"] {
            expectNotNil(theme.roles.first { $0.name == name })
        }
        if let path = ProcessInfo.processInfo.environment["GALLERY_IMPORT_PREVIEW"] {
            let arrow = theme.roles.first { $0.id == "com.apple.coregraphics.Arrow" }!
            for motion in Motion.allCases {
                if let clip = arrow.clip(motion) {
                    try clip.frames[clip.frames.count / 2].write(to: URL(fileURLWithPath: path).appendingPathComponent(motion.rawValue + ".png"))
                }
            }
        }
        let arrow = try require(theme.roles.first { $0.id == "com.apple.coregraphics.Arrow" })
        for id in ["com.apple.coregraphics.IBeam", "com.apple.cursor.23", "com.apple.cursor.19", "com.apple.cursor.3", "com.apple.cursor.4"] {
            let role = try require(theme.roles.first { $0.id == id })
            let choices = try require(role.variants[Motion.normal.rawValue])
            expectGreater(choices.count, 1)
            expectFalse(choices.filter { $0.clip.frames.count == 1 }.isEmpty)
            expectFalse(choices.filter { $0.clip.frames.count > 1 }.isEmpty)
            expectEqual(role.clip(.normal), choices.first?.clip)
        }
        for motion in Motion.allCases { expectNotNil(arrow.clip(motion)) }
        let clip = try require(arrow.clip(.press))
        expectGreater(clip.frames.count, 1)
        expectGreater(5.0, clip.duration)
        expectGreater(5.0, arrow.clip(.release)!.duration)
        let dictionary = try CursorImages.capeDictionary(clip)
        let roundtrip = try CursorImages.fromCape(dictionary)
        expectEqual(roundtrip.duration, clip.duration, accuracy: 0.000001)
    }
    func testVariantsPreserveEditsAndArchiveWithoutSourceFiles() throws {
        let red = try frame(.red), blue = try frame(.blue)
        let still = CursorClip(frames: [red]), animated = CursorClip(frames: [red, blue])
        var role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": still],
            variants: ["normal": [CursorVariant(id: "still", name: "静态", clip: still), CursorVariant(id: "animation", name: "动态", clip: animated)]],
            selectedVariants: ["normal": "still"])
        role.clips["normal"]?.hotX = 7
        role.selectVariant("animation", for: .normal)
        expectEqual(role.clip(.normal), animated)
        role.selectVariant("still", for: .normal)
        expectEqual(role.clip(.normal)?.hotX, 7)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("theme.gallery")
        let theme = GalleryTheme(name: "Variants", roles: [role])
        try ThemeFiles.save(theme, to: url)
        expectEqual(try ThemeFiles.load(url), theme)
        var invalid = theme; invalid.roles[0].selectedVariants["normal"] = "missing"
        expectThrows(try invalid.validate())
        var original = CursorRole(id: role.id, name: role.name, clips: ["normal": still])
        original.variants["normal"] = [CursorVariant(id: "animation", name: "动态", clip: animated)]
        original.selectVariant("animation", for: .normal)
        expectEqual(original.variants["normal"]?.count, 2)
        expectEqual(original.variants["normal"]?.last?.clip, still)
    }
}
