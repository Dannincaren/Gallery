import AppKit
import GalleryCore

final class ImportTests {
    func testANIWholeFileSizeCompatibilityAndTruncation() throws {
        func number(_ value: Int) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
        func chunk(_ name: String, _ payload: Data) -> Data {
            Data(name.utf8) + number(payload.count) + payload + Data(repeating: 0, count: payload.count % 2)
        }
        func cursor(_ color: NSColor) throws -> Data {
            let png = try frame(color)
            return Data([0, 0, 2, 0, 1, 0, 12, 12, 0, 0, 3, 0, 4, 0]) + number(png.count) + number(22) + png
        }
        let header = [36, 2, 2, 12, 12, 32, 1, 3, 1].reduce(into: Data()) { $0.append(number($1)) }
        let images = chunk("icon", try cursor(.red)) + chunk("icon", try cursor(.blue))
        let body = Data("ACON".utf8) + chunk("anih", header) + chunk("LIST", Data("fram".utf8) + images)
        let standard = Data("RIFF".utf8) + number(body.count) + body
        let expected = try AnimationImport.read(standard, extension: "ani")
        expectEqual(expected.hotX, 3); expectEqual(expected.hotY, 4)
        expectEqual(expected.duration, 0.1, accuracy: 0.000001)
        var exported = standard
        exported.replaceSubrange(4..<8, with: number(standard.count))
        expectEqual(try AnimationImport.read(exported, extension: "ani"), expected)
        for declared in [0, standard.count - 16, standard.count + 8, Int(UInt32.max)] {
            var invalid = standard; invalid.replaceSubrange(4..<8, with: number(declared))
            expectThrows(try AnimationImport.read(invalid, extension: "ani"))
        }
        for removed in [1, 8, 20] {
            var truncated = Data(exported.dropLast(removed))
            truncated.replaceSubrange(4..<8, with: number(truncated.count))
            expectThrows(try AnimationImport.read(truncated, extension: "ani"))
        }
        for extra in [Data([1]), Data(repeating: 0, count: 7)] {
            let dangling = standard + extra
            var invalid = dangling; invalid.replaceSubrange(4..<8, with: number(dangling.count - 8))
            expectThrows(try AnimationImport.read(invalid, extension: "ani"))
            let nested = body + chunk("LIST", Data("fram".utf8) + extra)
            let incompleteFrameChunk = Data("RIFF".utf8) + number(nested.count) + nested
            expectThrows(try AnimationImport.read(incompleteFrameChunk, extension: "ani"))
        }
        do {
            _ = try WindowsThemeImport.theme(files: ["pointer.ani": Data([0])], name: "Broken")
            preconditionFailure("Expected invalid ANI")
        } catch { expectEqual(error.localizedDescription.contains("pointer.ani"), true) }
    }
    func testRealAngelinaDirectoryOptionalIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["GALLERY_ANGELINA_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "ani" }
        expectEqual(files.count, 13)
        let theme = try WindowsThemeImport.load(directory)
        expectEqual(theme.name, "Angelina")
        expectFalse(theme.roles.contains { CursorCatalog.assetOnly($0.id) })
        let imported = Set(theme.roles.flatMap { $0.variants.values.flatMap { $0.map(\.id) } })
        expectEqual(imported, Set(files.map(\.lastPathComponent)))
        let arrow = try require(theme.roles.first { CursorCatalog.isArrow($0.id) }?.clip(.normal))
        let bitmap = try require(NSBitmapImageRep(data: arrow.frames[0]))
        let transparent = (0..<64).reduce(0) { total, y in
            total + (0..<64).filter { bitmap.colorAt(x: $0, y: y)!.alphaComponent < 0.01 }.count
        }
        expectEqual(transparent, 1064) // first source frame's AND-mask bits
        for file in files {
            let original = try Data(contentsOf: file)
            var standard = original
            standard.replaceSubrange(4..<8, with: (0..<4).map { UInt8(((original.count - 8) >> ($0 * 8)) & 255) })
            let clip = try AnimationImport.read(original, extension: "ani")
            expectEqual(clip, try AnimationImport.read(standard, extension: "ani"))
            expectGreater(clip.frames.count, 1); expectEqual(clip.width, 64); expectEqual(clip.height, 64)
            for role in theme.roles {
                if let variant = role.variants["normal"]?.first(where: { $0.id == file.lastPathComponent }) { expectEqual(variant.clip, clip) }
            }
        }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gallery")
        defer { try? FileManager.default.removeItem(at: archive) }
        try ThemeFiles.save(theme, to: archive); expectEqual(try ThemeFiles.load(archive), theme)
    }
    func testWindowsINFMappingAndUnclassifiedAssets() throws {
        let png = try frame(.red)
        var cur = Data([0, 0, 2, 0, 1, 0, 12, 12, 0, 0, 3, 0, 4, 0])
        for n in [png.count, 22] { cur.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        cur.append(png)
        let inf = """
        [Any.Reg]
        HKCU,"Control Panel\\Cursors",Arrow,0x00020000,"%10%\\%CUR_DIR%\\%pointer%"
        HKCU,"Control Panel\\Cursors",SizeNWSE,0x00020000,"%diag%"
        [Strings]
        SCHEME_NAME = "测试方案"
        pointer = "CustomPointer.CUR"
        diag = "Slope.cur"
        CUR_DIR = "Cursors\\Test"
        """
        let files = ["payload/CustomPointer.CUR": cur, "Slope.cur": cur, "Sparkle.cur": cur,
                     "payload/CustomPointer_hold.cur": cur, "install.inf": inf.data(using: .utf16)!]
        let theme = try WindowsThemeImport.theme(files: files, name: "Fallback")
        expectEqual(theme.name, "测试方案")
        let arrow = try require(theme.roles.first { $0.id == "com.apple.coregraphics.Arrow" })
        expectEqual(arrow.clip(.normal)?.hotX, 3)
        expectNotNil(arrow.clip(.hold))
        expectNotNil(theme.roles.first { $0.id == "com.apple.cursor.35" })
        expectFalse(theme.roles.contains { $0.id == "com.apple.cursor.29" })
        expectEqual(theme.roles.filter { CursorCatalog.assetOnly($0.id) }.map(\.name), ["Sparkle.cur"])
        expectThrows(try WindowsThemeImport.theme(files: ["Sparkle.cur": cur, "install.inf": inf.data(using: .utf8)!], name: "Missing"))
        let explosive = "[Reg]\nHKCU,\"Control Panel\\Cursors\",Arrow,0,\"%a%\"\n[Strings]\na=\"" + String(repeating: "%b%", count: 500) + "\"\nb=\"" + String(repeating: "x", count: 500) + "\""
        expectThrows(try WindowsThemeImport.theme(files: ["Sparkle.cur": cur, "install.inf": Data(explosive.utf8)], name: "Invalid"))
    }
    func testCursorDirectoryNamingAndINFPrecedence() throws {
        let png = try frame(.blue)
        var cur = Data([0, 0, 2, 0, 1, 0, 12, 12, 0, 0, 2, 0, 5, 0])
        for n in [png.count, 22] { cur.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }; cur.append(png)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["pointer.cur", "text.cur", "vert.cur", "horz.cur", "dgn1.cur", "dgn2.cur"] { try cur.write(to: root.appendingPathComponent(file)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside.cur"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("not-a-cursor"))
        let folder = try WindowsThemeImport.load(root)
        for id in ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.IBeam", "com.apple.cursor.23", "com.apple.cursor.19", "com.apple.cursor.35", "com.apple.cursor.29"] {
            expectNotNil(folder.roles.first { $0.id == id })
        }
        expectFalse(folder.roles.contains { CursorCatalog.assetOnly($0.id) })
        let special = root.appendingPathComponent("pointer[1].cur")
        try cur.write(to: special)
        let zip = root.appendingPathComponent("Special.zip"), zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipper.arguments = ["-j", zip.path, special.path]; zipper.standardOutput = FileHandle.nullDevice; zipper.standardError = FileHandle.nullDevice
        try zipper.run(); zipper.waitUntilExit()
        expectEqual(zipper.terminationStatus, 0)
        let literalZIP = try WindowsThemeImport.load(zip)
        expectEqual(literalZIP.roles.map(\.name), ["pointer[1].cur"])

        let inf = "[Reg]\nHKCU,\"Control Panel\\Cursors\",SizeNWSE,0,\"dgn2.cur\""
        let configured = try WindowsThemeImport.theme(files: ["dgn2.cur": cur, "配置.inf": Data(inf.utf8)], name: "Configuration wins")
        expectNotNil(configured.roles.first { $0.id == "com.apple.cursor.35" })
        expectFalse(configured.roles.contains { $0.id == "com.apple.cursor.29" })
    }
    func testRealWindowsEXEOptionalIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["GALLERY_WINDOWS_EXE"] else { return }
        let input = URL(fileURLWithPath: path)
        let resources = try WindowsResources(data: Data(contentsOf: input))
        let assets = Set(resources.entries.keys.filter { $0.lowercased().hasSuffix(".ani") || $0.lowercased().hasSuffix(".cur") })
        expectEqual(assets.count, 17)
        let theme = try WindowsThemeImport.load(input)
        expectEqual(theme.name, "mon3tr鼠标")
        let imported = Set(theme.roles.flatMap { $0.variants.values.flatMap { $0.map(\.id) } })
        expectEqual(imported, assets)
        for role in theme.roles {
            for variants in role.variants.values {
                for variant in variants {
                    let decoded = try AnimationImport.read(try require(resources.resource(named: variant.id)), extension: "ani")
                    expectEqual(variant.clip, decoded)
                }
            }
        }
        expectFalse(theme.roles.contains { $0.clip(.press) != nil || $0.clip(.release) != nil })
        expectEqual(theme.roles.first { $0.id == "com.apple.cursor.35" }?.selectedVariants["normal"], ".InstallCache/Diagonal1.ani")
        expectEqual(theme.roles.first { $0.id == "com.apple.cursor.29" }?.selectedVariants["normal"], ".InstallCache/Diagonal2.ani")
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gallery")
        defer { try? FileManager.default.removeItem(at: archive) }
        try ThemeFiles.save(theme, to: archive); expectEqual(try ThemeFiles.load(archive), theme)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for asset in resources.entries.keys {
            let filename = URL(fileURLWithPath: asset).lastPathComponent
            try resources.resource(named: asset)!.write(to: directory.appendingPathComponent(filename))
        }
        let fromFolder = try WindowsThemeImport.load(directory)
        expectEqual(fromFolder.name, theme.name)
        expectEqual(fromFolder.roles.map(\.clips), theme.roles.map(\.clips))
        let fromINF = try WindowsThemeImport.load(directory.appendingPathComponent("install.inf"))
        expectEqual(fromINF, fromFolder)
        if let zip = ProcessInfo.processInfo.environment["GALLERY_WINDOWS_ZIP"] {
            let zipped = try WindowsThemeImport.load(URL(fileURLWithPath: zip))
            expectEqual(zipped.name, theme.name)
            expectEqual(zipped.roles.map(\.clips), theme.roles.map(\.clips))
        }
    }
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
    func test24BitCURMaskAndRowPadding() throws {
        var payload = Data()
        func number(_ n: Int, _ size: Int = 4) { payload.append(contentsOf: (0..<size).map { UInt8((n >> ($0 * 8)) & 255) }) }
        number(40); number(2); number(4); number(1, 2); number(24, 2)
        number(0); number(16); number(0); number(0); number(0); number(0)
        // BGR rows are DWORD aligned: two blue pixels below two red pixels.
        payload.append(contentsOf: [255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0])
        payload.append(contentsOf: [0, 0, 0, 0, 0x80, 0, 0, 0]) // top-left transparent
        func cursor(_ payload: Data) -> Data {
            var cur = Data([0, 0, 2, 0, 1, 0, 2, 2, 0, 0, 1, 0, 1, 0])
            for n in [payload.count, 22] { cur.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
            return cur + payload
        }
        let clip = try AnimationImport.read(cursor(payload), extension: "cur")
        let image = try require(NSBitmapImageRep(data: clip.frames[0]))
        expectEqual(image.colorAt(x: 0, y: 0)!.alphaComponent, 0)
        expectGreater(image.colorAt(x: 1, y: 0)!.usingColorSpace(.deviceRGB)!.redComponent, 0.9)
        expectGreater(image.colorAt(x: 1, y: 1)!.usingColorSpace(.deviceRGB)!.blueComponent, 0.9)
        expectGreater(image.colorAt(x: 1, y: 1)!.alphaComponent, 0.9)
        expectEqual(clip.hotX, 1); expectEqual(clip.hotY, 1)
        expectThrows(try AnimationImport.read(cursor(Data(payload.dropLast(1))), extension: "cur"))
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
