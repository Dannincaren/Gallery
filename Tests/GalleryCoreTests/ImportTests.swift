import AppKit
import Compression
import CoreFoundation
import GalleryCore

final class ImportTests {
    func testZIP64LegacyNamesStreamingCRCAndSelfExtractor() throws {
        func number(_ value: Int, _ bytes: Int = 4) -> Data { Data((0..<bytes).map { UInt8((value >> ($0 * 8)) & 255) }) }
        func joined(_ pieces: Data...) -> Data { pieces.reduce(into: Data()) { $0.append($1) } }
        func checksum(_ data: Data) -> Int {
            var crc = UInt32.max
            for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 } }
            return Int(~crc)
        }
        expectEqual(checksum(Data("123456789".utf8)), 0xcbf43926)
        let original = try smallCursor(), payload = original + Data(repeating: 0, count: 180000)
        func archive(name: Data, deflated: Bool, zip64: Bool, corruptCRC: Bool = false) -> Data {
            let crc = checksum(payload) ^ (corruptCRC ? 1 : 0)
            var encoded = payload
            if deflated {
                var output = [UInt8](repeating: 0, count: payload.count * 2)
                let count = payload.withUnsafeBytes { input in output.withUnsafeMutableBytes { output in
                    compression_encode_buffer(output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count,
                        input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count, nil, COMPRESSION_ZLIB)
                } }
                expectGreater(count, 0); encoded = Data(output.prefix(count))
            }
            let method = deflated ? 8 : 0
            let sizes = number(crc) + number(encoded.count) + number(payload.count)
            var data = joined(number(0x04034b50), number(20, 2), number(0, 2), number(method, 2), number(0), sizes)
            data += number(name.count, 2) + number(0, 2) + name + encoded
            let start = data.count
            var directory = joined(number(0x02014b50), number(20, 2), number(zip64 ? 45 : 20, 2), number(0, 2), number(method, 2), number(0), number(crc))
            directory += number(zip64 ? 0xffffffff : encoded.count) + number(zip64 ? 0xffffffff : payload.count)
            let extra = zip64 ? joined(number(1, 2), number(24, 2), number(payload.count, 8), number(encoded.count, 8), number(0, 8)) : Data()
            directory += joined(number(name.count, 2), number(extra.count, 2), number(0, 2), number(0, 2), number(0, 2), number(0), number(zip64 ? 0xffffffff : 0), name, extra)
            data += directory
            if zip64 {
                let header = data.count
                data += joined(number(0x06064b50), number(44, 8), number(45, 2), number(45, 2), number(0), number(0), number(1, 8), number(1, 8), number(directory.count, 8), number(start, 8))
                data += number(0x07064b50) + number(0) + number(header, 8) + number(1)
            }
            data += number(0x06054b50) + number(0, 2) + number(0, 2)
            data += number(zip64 ? 0xffff : 1, 2) + number(zip64 ? 0xffff : 1, 2)
            data += number(zip64 ? 0xffffffff : directory.count) + number(zip64 ? 0xffffffff : start) + number(0, 2)
            return data
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Theme.zip")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let name = try require("中文目录/normal.cur".data(using: gb))
        for compressed in [false, true] { for zip64 in [false, true] {
            let bytes = archive(name: name, deflated: compressed, zip64: zip64); try bytes.write(to: file)
            let theme = try WindowsThemeImport.load(file)
            expectNotNil(theme.roles.first { CursorCatalog.isArrow($0.id) })
            expectEqual(theme.roles.first?.clip(.normal)?.frames.count, 1)
            try archive(name: name, deflated: compressed, zip64: zip64, corruptCRC: true).write(to: file)
            expectThrows(try WindowsThemeImport.load(file))
        } }
        try archive(name: Data("../normal.cur".utf8), deflated: false, zip64: false).write(to: file)
        expectThrows(try WindowsThemeImport.load(file))
        let executable = root.appendingPathComponent("Self Extractor.exe")
        try (Data([0x4d, 0x5a]) + Data(repeating: 0, count: 62) + archive(name: Data("normal.cur".utf8), deflated: true, zip64: false)).write(to: executable)
        expectNotNil(try WindowsThemeImport.load(executable).roles.first { CursorCatalog.isArrow($0.id) })
    }
    func testConfiguredSetsInFolderZIPAndDirectINF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Theme A", "主题 B"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try smallCursor().write(to: folder.appendingPathComponent("NORMAL.CUR"))
            let inf = "[Cursors]\nHKCU,\"Control Panel\\Cursors\",Arrow,0,normal.cur\n[Strings]\nSCHEME_NAME=\"\(name)\""
            try (Data([0xff, 0xfe]) + require(inf.data(using: .utf16LittleEndian))).write(to: folder.appendingPathComponent("install.inf"))
        }
        let folder = try WindowsThemeImport.candidates(root)
        expectEqual(folder.map(\.name), ["Theme A", "主题 B"])
        let direct = try WindowsThemeImport.candidates(root.appendingPathComponent("主题 B/install.inf"))
        expectEqual(direct.map(\.name), ["主题 B"])
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try zipFolder(root, to: archive)
        expectEqual(try WindowsThemeImport.candidates(archive).map(\.name), folder.map(\.name))
    }
    func testSingleFileManagedBundlesCompressedAndDirectCursors() throws {
        func number(_ value: Int, _ bytes: Int = 4) -> Data { Data((0..<bytes).map { UInt8((value >> ($0 * 8)) & 255) }) }
        func text(_ value: String) -> Data { precondition(value.utf8.count < 128); return Data([UInt8(value.utf8.count)]) + Data(value.utf8) }
        let assembly = installerFixture(try smallCursor())
        func bundle(version: Int, compressed: Bool) throws -> Data {
            var stored = assembly
            if compressed {
                var bytes = [UInt8](repeating: 0, count: assembly.count * 2 + 64)
                let count = assembly.withUnsafeBytes { input in bytes.withUnsafeMutableBytes { output in
                    compression_encode_buffer(output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count,
                        input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count, nil, COMPRESSION_ZLIB)
                } }
                expectGreater(count, 0); stored = Data(bytes.prefix(count))
            }
            var data = Data([0x4d, 0x5a]) + Data(repeating: 0, count: 126)
            let start = data.count; data += stored; data += stored
            let header = data.count
            data.replaceSubrange(16..<24, with: number(header, 8))
            let signature: [UInt8] = [0x8b,0x12,0x02,0xb9,0x6a,0x61,0x20,0x38,0x72,0x7b,0x93,0x02,0x14,0xd7,0xa0,0x32,
                                     0x13,0xf5,0xb9,0xe6,0xef,0xae,0x33,0x18,0xee,0x3b,0x2d,0xce,0x24,0xb3,0x6a,0xae]
            data.replaceSubrange(24..<56, with: signature)
            data += number(version) + number(0) + number(2) + text("test-bundle")
            if version >= 2 { data += Data(repeating: 0, count: 40) }
            for (offset, name) in [(start, "Theme.dll"), (start + stored.count, "Theme.r2r.dll")] {
                data += number(offset, 8) + number(assembly.count, 8)
                if version >= 6 { data += number(compressed ? stored.count : 0, 8) }
                data += Data([1]) + text(name)
            }
            return data
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Theme's Installer.exe")
        for (version, compressed) in [(1, false), (2, false), (6, false), (6, true)] {
            let data = try bundle(version: version, compressed: compressed); try data.write(to: url)
            let themes = try WindowsThemeImport.candidates(url)
            expectEqual(themes.count, 1) // duplicate ReadyToRun assets do not import twice
            expectNotNil(themes[0].roles.first { CursorCatalog.isArrow($0.id) })
            expectThrows(try { try Data(data.dropLast()).write(to: url); return try WindowsThemeImport.load(url) }())
            var invalid = data; invalid.replaceSubrange(16..<24, with: number(data.count + 1, 8)); try invalid.write(to: url)
            expectThrows(try WindowsThemeImport.load(url))
        }
        try bundle(version: 6, compressed: true).write(to: url)
        var oversized = try bundle(version: 6, compressed: true)
        let manifest = (0..<8).reduce(0) { $0 | (Int(oversized[16 + $1]) << ($1 * 8)) }
        let first = manifest + 12 + text("test-bundle").count + 40
        oversized.replaceSubrange(first + 8..<first + 16, with: number(80_000_001, 8)); try oversized.write(to: url)
        expectThrows(try WindowsThemeImport.load(url))
        try bundle(version: 6, compressed: true).write(to: url)
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try zipFolder(root, to: archive)
        expectEqual(try WindowsThemeImport.candidates(archive).count, 1)
        let single = root.appendingPathComponent("Custom.cur"); try smallCursor().write(to: single)
        let imported = try WindowsThemeImport.load(single)
        expectEqual(imported.roles.map(\.id), ["com.apple.coregraphics.Arrow"])
        let chunk: (String, Data) -> Data = { name, data in Data(name.utf8) + number(data.count) + data + Data(repeating: 0, count: data.count % 2) }
        let header = [36, 2, 2, 12, 12, 32, 1, 3, 1].reduce(into: Data()) { $0 += number($1) }
        let frames = chunk("icon", try smallCursor()) + chunk("icon", try smallCursor())
        let body = Data("ACON".utf8) + chunk("anih", header) + chunk("LIST", Data("fram".utf8) + frames)
        let animated = root.appendingPathComponent("Text.ani"); try (Data("RIFF".utf8) + number(body.count) + body).write(to: animated)
        expectEqual(try require(WindowsThemeImport.load(animated).roles.first?.clip(.normal)).duration, 0.1, accuracy: 0.000001)
    }
    func testLiveRasterLayoutScaleAndBounds() throws {
        let frames = [try frame(.red), try frame(.blue), try frame(.green)]
        let images = try frames.map(CursorImages.bitmap)
        let clip = CursorClip(frames: frames, width: 31.5, height: 20.5, hotX: 4, hotY: 8)
        for smooth in [false, true] {
            let rasters = try CursorImages.rasters(images, width: clip.width, height: clip.height, smoothEdges: smooth)
            expectEqual(rasters.map(\.width), [32, 63, 95])
            expectEqual(rasters.map(\.height), [63, 123, 186])
            for raster in rasters {
                let height = raster.height / frames.count
                for index in frames.indices {
                    let cropped = try require(raster.cropping(to: CGRect(x: 0, y: index * height, width: raster.width, height: height)))
                    let actual = try require(CursorFingerprint(image: cropped, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY))
                    let source = try require(CursorFingerprint(image: images[index], width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY))
                    expectEqual(actual.visualDistance(to: source), 0, accuracy: 0.001)
                }
            }
            expectEqual(try CursorImages.rasters(images, width: 32, height: 32, smoothEdges: smooth, maximumScale: 2).count, 2)
        }
        expectThrows(try CursorImages.rasters([], width: 32, height: 32))
        expectThrows(try CursorImages.rasters(images, width: .nan, height: 32))
        expectThrows(try CursorImages.rasters(images, width: 129, height: 32))
        expectThrows(try CursorImages.rasters(images, width: 32, height: 32, maximumScale: 0))
        expectThrows(try CursorImages.rasters(Array(repeating: images[0], count: 25), width: 32, height: 32))
    }
    func testImportChoicesKeepEditsAliasesAndRequiredNormals() throws {
        let still = CursorClip(frames: [try frame(.red)])
        let loop = CursorClip(frames: [try frame(.red), try frame(.blue)])
        var role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": still, "press": loop],
            variants: ["normal": [CursorVariant(id: "still", name: "Static", clip: still), CursorVariant(id: "loop", name: "Loop", clip: loop)],
                       "press": [CursorVariant(id: "click", name: "Click", clip: loop)]],
            selectedVariants: ["normal": "still", "press": "click"])
        role.clips["normal"]?.hotX = 7
        var alias = role; alias.id = "com.apple.cursor.0"
        let original = GalleryTheme(name: "Choices", roles: [role, alias])
        expectEqual(ImportSelection.hasAlternatives(original), true)
        let normal = ImportSelection.key(role: role.id, motion: .normal)
        expectEqual(normal, ImportSelection.key(role: alias.id, motion: .normal))
        let retained = try ImportSelection.keeping([normal: ["still"]], in: original)
        for value in retained.roles {
            expectEqual(value.clip(.normal)?.hotX, 7)
            expectEqual(value.variants["normal"]?.map(\.id), ["still"])
            expectEqual(value.clip(.press), loop)
        }
        let changed = try ImportSelection.keeping([normal: ["loop"], ImportSelection.key(role: role.id, motion: .press): []], in: original)
        for value in changed.roles {
            expectEqual(value.clip(.normal), loop)
            expectEqual(value.selectedVariants["normal"], "loop")
            expectEqual(value.clip(.press), nil)
            expectEqual(value.variants["press"], nil)
            expectEqual(value.selectedVariants["press"], nil)
        }
        expectThrows(try ImportSelection.keeping([normal: []], in: original))
        expectEqual(try ImportSelection.keeping([:], in: original), original)
        expectEqual(original.roles[0].variants["normal"]?.count, 2)
    }
    func testInnoGroupingFilteringAndBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cursor = try smallCursor()
        for name in ["cirno/cursors", "cirno/cursors_minimal"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in ["pointer.cur", "busy.cur", "wait.cur"] { try cursor.write(to: directory.appendingPathComponent(file)) }
            try Data("ignored wallpaper".utf8).write(to: directory.appendingPathComponent("wallpaper.png"))
        }
        let themes = try InnoCursorImport.themes(in: root, packageName: "Cursor Package")
        expectEqual(themes.map(\.name), ["Cursor Package · cirno", "Cursor Package · cirno · 简约"])
        for theme in themes {
            expectEqual(theme.roles.first { CursorCatalog.isArrow($0.id) }?.selectedVariants["normal"], "pointer.cur")
            expectEqual(theme.roles.first { $0.id == "com.apple.coregraphics.Wait" }?.selectedVariants["normal"], "wait.cur")
            expectEqual(theme.roles.first { $0.name == "后台运行" }?.selectedVariants["normal"], "busy.cur")
            expectFalse(theme.roles.contains { CursorCatalog.assetOnly($0.id) })
        }
        let exe = root.appendingPathComponent("Fake.exe")
        try (Data([0x4d, 0x5a]) + Data("Inno Setup Setup Data (7.0.0.3)".utf8)).write(to: exe)
        expectEqual(try InnoCursorImport.recognizes(exe), true)
        try Data("Inno Setup Setup Data (7.0.0.3)".utf8).write(to: exe)
        expectEqual(try InnoCursorImport.recognizes(exe), false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.cur"), withDestinationURL: exe)
        expectThrows(try InnoCursorImport.themes(in: root, packageName: "Unsafe"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("escape.cur"))
        let oversized = root.appendingPathComponent("cirno/cursors/too-big.cur")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 40_000_001); try handle.close()
        expectThrows(try InnoCursorImport.themes(in: root, packageName: "Oversized"))
    }
    func testRegisteredRasterIdentificationIsAppliedAtEveryScale() throws {
        let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 384,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 47, y: 5, width: 2, height: 86))
        context.fill(CGRect(x: 35, y: 5, width: 26, height: 2))
        context.fill(CGRect(x: 35, y: 89, width: 26, height: 2))
        let clip = CursorClip(frames: [try CursorImages.png(context.makeImage()!)], width: 32, height: 32, hotX: 16, hotY: 16).scaled(by: 1.425)
        let dictionary = try CursorImages.capeDictionary(clip)
        let role = "com.apple.coregraphics.IBeam"
        var matcher = CursorMatcher(); matcher.addRepresentations(dictionary, role: role, applied: true)
        for data in dictionary["Representations"] as! [Data] {
            let image = try CursorImages.bitmap(data)
            let actual = matcher.identify(image: image, width: Double(image.width), height: Double(image.height),
                hotX: floor(clip.hotX / clip.width * Double(image.width)), hotY: floor(clip.hotY / clip.height * Double(image.height)))
            expectEqual(actual.roles, [role]); expectEqual(actual.appliedRoles, [role])
        }
    }
    // A data-only PE/CLI fixture: one embedded cursor and no executable code.
    private func installerFixture(_ cursor: Data) -> Data {
        var bytes = Data(repeating: 0, count: 0x504 + cursor.count)
        func put(_ value: Int, at offset: Int, count: Int = 4) {
            bytes.replaceSubrange(offset..<offset + count, with: (0..<count).map { UInt8((value >> ($0 * 8)) & 255) })
        }
        put(0x5a4d, at: 0, count: 2); put(0x80, at: 0x3c); put(0x4550, at: 0x80)
        put(1, at: 0x86, count: 2); put(224, at: 0x94, count: 2); put(0x10b, at: 0x98, count: 2)
        put(0x2000, at: 0x98 + 96 + 14 * 8)
        put(0x2000, at: 0x178 + 12); put(bytes.count - 0x200, at: 0x178 + 16); put(0x200, at: 0x178 + 20)
        put(0x2080, at: 0x208); put(0x2300, at: 0x218); put(4 + cursor.count, at: 0x21c)
        put(0x424a5342, at: 0x280); put(4, at: 0x28c); put(2, at: 0x296, count: 2)
        let strings = Data([0]) + Data("normal.cur\0".utf8)
        put(0x100, at: 0x298); put(strings.count, at: 0x29c)
        bytes.replaceSubrange(0x2a0..<0x2a9, with: Data("#Strings\0".utf8))
        put(0x120, at: 0x2ac); put(40, at: 0x2b0)
        bytes.replaceSubrange(0x2b4..<0x2b7, with: Data("#~\0".utf8))
        bytes.replaceSubrange(0x380..<0x380 + strings.count, with: strings)
        put(1, at: 0x3a0 + 13, count: 1) // ManifestResource is metadata table 40.
        put(1, at: 0x3a0 + 24); put(1, at: 0x3a0 + 28 + 4); put(1, at: 0x3a0 + 28 + 8, count: 2)
        put(cursor.count, at: 0x500); bytes.replaceSubrange(0x504..<bytes.count, with: cursor)
        return bytes
    }
    private func smallCursor() throws -> Data {
        let png = try frame(.red)
        var cur = Data([0, 0, 2, 0, 1, 0, 12, 12, 0, 0, 3, 0, 4, 0])
        for value in [png.count, 22] { cur.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
        return cur + png
    }
    private func zipFolder(_ root: URL, to zip: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zip.path, "."]; process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); expectEqual(process.terminationStatus, 0)
    }
    func testTwoGBPackageLimitAndMappedLargeInstaller() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Large.exe"), cursor = try smallCursor()
        try installerFixture(cursor).write(to: url)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        // Sparse padding exercises the real loader above the old limit and at
        // the new limit without allocating gigabytes of test data or disk.
        for size in [600_000_001, WindowsResources.maximumInstallerBytes] {
            try handle.truncate(atOffset: UInt64(size))
            let theme = try WindowsThemeImport.load(url)
            expectEqual(theme.roles.first { CursorCatalog.isArrow($0.id) }?.clip(.normal), try AnimationImport.read(cursor, extension: "cur"))
        }
        try handle.truncate(atOffset: UInt64(WindowsResources.maximumInstallerBytes + 1))
        for file in [url, root.appendingPathComponent("TooLarge.zip")] {
            if file != url { try FileManager.default.moveItem(at: url, to: file) }
            do { _ = try WindowsThemeImport.load(file); preconditionFailure("Expected 2 GB package limit") }
            catch { expectEqual(error.localizedDescription.contains("2 GB"), true) }
        }
    }
    func testMixedBundlesImportOnlyCursorAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = root.appendingPathComponent("Mixed")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try smallCursor().write(to: payload.appendingPathComponent("normal.cur"))
        let unrelated = Data("not a cursor or installer".utf8)
        for name in ["wallpaper.png", "application.ico", "readme.txt", "PRTS-Setup.exe"] {
            try unrelated.write(to: payload.appendingPathComponent(name))
        }
        let inf = "[Reg]\nHKCU,\"Control Panel\\Desktop\",Wallpaper,0,wallpaper.png\n[Strings]\nSCHEME_NAME=WrongWallpaperName"
        try Data(inf.utf8).write(to: payload.appendingPathComponent("wallpaper.inf"))
        let folder = try WindowsThemeImport.load(payload)
        expectEqual(folder.name, "Mixed"); expectFalse(folder.roles.contains { CursorCatalog.assetOnly($0.id) })
        let zip = root.appendingPathComponent("Mixed.zip"); try zipFolder(payload, to: zip)
        let archived = try WindowsThemeImport.load(zip)
        expectEqual(archived.name, folder.name); expectEqual(archived.roles.map(\.clips), folder.roles.map(\.clips))
        expectEqual(try Data(contentsOf: payload.appendingPathComponent("application.ico")), unrelated)
    }
    func testZIPStreamsInstallerWithUnrelatedConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = root.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try installerFixture(smallCursor()).write(to: payload.appendingPathComponent("Cursor[1].exe"))
        try Data("[Strings]\nSCHEME_NAME=Wallpaper".utf8).write(to: payload.appendingPathComponent("wallpaper.inf"))
        try Data(repeating: 0, count: 1000).write(to: payload.appendingPathComponent("wallpaper.jpg"))
        let zip = root.appendingPathComponent("InstallerBundle.zip"); try zipFolder(payload, to: zip)
        let theme = try WindowsThemeImport.load(zip)
        expectEqual(theme.name, "Cursor[1]")
        expectNotNil(theme.roles.first { CursorCatalog.isArrow($0.id) })
        expectFalse(theme.roles.contains { CursorCatalog.assetOnly($0.id) })
    }
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
    func testRealCursorDirectoryOptionalIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["GALLERY_CURSOR_DIRECTORY"] ?? ProcessInfo.processInfo.environment["GALLERY_ANGELINA_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "ani" }
        expectEqual(files.count, 13)
        let theme = try WindowsThemeImport.load(directory)
        expectFalse(theme.name.isEmpty)
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
        expectFalse(theme.name.isEmpty)
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
    func testRealManagedResourceOptionalIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["GALLERY_RESOURCE_EXE"] ?? ProcessInfo.processInfo.environment["GALLERY_PRTS_EXE"] else {
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
