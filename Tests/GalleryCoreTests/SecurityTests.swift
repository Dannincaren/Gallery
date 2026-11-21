import AppKit
import Darwin
import GalleryCore

final class SecurityTests {
    private func image(_ size: Int = 8) throws -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try CursorImages.png(context.makeImage()!)
    }
    private func number(_ n: Int, _ bytes: Int = 4) -> Data { Data((0..<bytes).map { UInt8((n >> ($0 * 8)) & 255) }) }
    private func cur(_ png: Data) -> Data {
        Data([0,0,2,0,1,0,8,8,0,0,0,0,0,0]) + number(png.count) + number(22) + png
    }
    func testGeometryAndIdentifiers() throws {
        let png = try image(), clip = CursorClip(frames: [png])
        for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            expectEqual(CursorImages.signature(png, hotX: invalid, hotY: 0, width: 32, height: 32), nil)
            expectEqual(CursorImages.signature(png, hotX: 0, hotY: 0, width: invalid, height: 32), nil)
        }
        expectEqual(CursorImages.signature(png, hotX: 33, hotY: 0, width: 32, height: 32), nil)
        for id in ["com.apple.coregraphics.Arrow\0suffix", "com.apple.cursor.1/../../x", "com.apple." + String(repeating: "x", count: 300)] {
            expectThrows(try GalleryTheme(name: "Untrusted", roles: [CursorRole(id: id, name: "X", clips: ["normal": clip])]).validate())
        }
        expectThrows(try AnimationImport.read(cur(image(32)), extension: "cur"))
        let cape: [String: Any] = ["Representations": Array(repeating: png, count: 17), "FrameCount": 1, "PointsWide": 32, "PointsHigh": 32]
        expectThrows(try CursorImages.fromCape(cape))
    }
    func testCumulativeImageBudgetAndSharedFrames() throws {
        // Build one 16 MiB bitmap, then share its compressed bytes. Metadata
        // preflight must reject 33 distinct 4M-pixel images before decoding.
        let png = try autoreleasepool { try image(2048) }
        let shared = CursorClip(frames: Array(repeating: png, count: 240))
        let roles = (0..<80).map { CursorRole(id: "com.apple.audit.\($0)", name: "X", clips: ["normal": shared]) }
        try CursorImages.validateResources(GalleryTheme(name: "Shared", roles: roles))
        let unique = (0..<33).map { png + Data([UInt8($0)]) }
        let costly = CursorRole(id: "com.apple.audit", name: "Cost", clips: ["normal": CursorClip(frames: unique)])
        expectThrows(try CursorImages.validateResources(GalleryTheme(name: "Cost", roles: [costly])))
    }
    func testBoundedFilesRejectLinksSpecialFilesAndOversize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("normal.cur"); try cur(image()).write(to: original)
        _ = try AnimationImport.read(original)
        let link = root.appendingPathComponent("linked.cur")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        expectThrows(try AnimationImport.read(link))
        let fifo = root.appendingPathComponent("pipe.gallery"); expectEqual(mkfifo(fifo.path, 0o600), 0)
        expectThrows(try ThemeFiles.load(fifo))
        let large = root.appendingPathComponent("large.gallery")
        expectEqual(FileManager.default.createFile(atPath: large.path, contents: nil), true)
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 80_000_001); try handle.close()
        expectThrows(try ThemeFiles.load(large))
    }
    func testLongANISelectsBeforeDecodeWithoutChangingTiming() throws {
        let cursor = try cur(image()), count = 1000
        var header = Data(repeating: 0, count: 36)
        for (offset, value) in [(0,36),(4,count),(8,count),(28,3),(32,1)] { header.replaceSubrange(offset..<offset + 4, with: number(value)) }
        var list = Data("fram".utf8)
        for _ in 0..<count { list += Data("icon".utf8) + number(cursor.count) + cursor; if cursor.count % 2 != 0 { list.append(0) } }
        let chunks = Data("anih".utf8) + number(header.count) + header + Data("LIST".utf8) + number(list.count) + list
        let ani = Data("RIFF".utf8) + number(chunks.count + 4) + Data("ACON".utf8) + chunks
        let decoded = try AnimationImport.read(ani, extension: "ani")
        expectEqual(decoded.frames.count, 240); expectEqual(Set(decoded.frames).count, 1)
        expectEqual(abs(decoded.duration - 50) < 0.000001, true)
    }
}
