import Foundation
import AppKit
import GalleryCore

final class RegressionTests {
    func testGlobalAnimationFilmstripObservation() throws {
        let helper = ImportTests()
        let clip = CursorClip(frames: try [NSColor.red, .blue, .green].map { try helper.frame($0) }, hotX: 4, hotY: 4)
        let registered = try CursorImages.capeDictionary(clip)
        var global = registered
        global["FrameCount"] = 1; global["PointsHigh"] = clip.height * 3
        var matcher = CursorMatcher(); matcher.add(clip, role: "animated")
        expectEqual(matcher.matchCurrent(global), ["animated"])
        var wrong = global; wrong["HotSpotX"] = clip.width * 0.9
        expectEqual(matcher.matchCurrent(wrong), [])
    }
    func testSizeScalesGeometryAndLeavesSourceUntouched() throws {
        let clip = CursorClip(frames: [try ImportTests().frame(.red)], width: 32, height: 24, hotX: 5, hotY: 7)
        let large = clip.scaled(by: 2)
        expectEqual(large.width, 64); expectEqual(large.height, 48)
        expectEqual(large.hotX, 10); expectEqual(large.hotY, 14)
        expectEqual(large.frames, clip.frames); expectEqual(clip.width, 32)
        try large.validate(); try clip.scaled(by: 100).validate()
        expectEqual(clip.scaled(by: .nan), clip)
    }
    func testUnsplitClickAutomaticallyPlaysRelease() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 0.1, enabled: true, split: false, releaseDuration: 0.2)
        m.up(now: 1.01, releaseDuration: 0.2, enabled: true)
        expectEqual(m.motion, .press)
        m.tick(now: 1.11, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motion, .release)
        m.tick(now: 1.31, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motion, .normal)
    }
    func testUnsplitClickCompletesWithoutHoldOrRelease() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 0.5, enabled: true, split: false)
        m.up(now: 1.01, releaseDuration: 1, enabled: true)
        expectEqual(m.motion, .press)
        m.tick(now: 1.51, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motion, .normal)
        m.down(now: 2, pressDuration: 0.2, enabled: true, split: false)
        m.tick(now: 2.3, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motion, .normal)
    }
    func testRoleDefaultsAndLegacyMigration() throws {
        let clip = CursorClip(frames: [try ImportTests().frame(.red)])
        for descriptor in CursorCatalog.all {
            let role = CursorRole(id: descriptor.id, name: descriptor.title, clips: ["normal": clip])
            expectEqual(role.splitClickAnimation, CursorCatalog.isArrow(descriptor.id))
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(role)) as! [String: Any]
            object.removeValue(forKey: "splitClickAnimation")
            let legacy = try JSONDecoder().decode(CursorRole.self, from: JSONSerialization.data(withJSONObject: object))
            expectEqual(legacy.splitClickAnimation, role.splitClickAnimation)
        }
    }
    func testPassiveQuickClickAndCounterWrap() {
        var edges = MouseEdgeTracker(downs: .max, ups: .max)
        expectEqual(edges.observe(downs: 0, ups: 0, isDown: false), [.down, .up])
        expectEqual(edges.observe(downs: 0, ups: 0, isDown: false), [])
        expectEqual(edges.observe(downs: 1, ups: 0, isDown: true), [.down])
        expectEqual(edges.observe(downs: 2, ups: 1, isDown: true), [.up, .down])
    }
    func testArchiveDeduplicatesAndPreservesOverrides() throws {
        let clip = CursorClip(frames: [try ImportTests().frame(.red)])
        let role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "正常选择", clips: ["normal": clip, "press": clip], splitClickAnimation: false)
        let theme = GalleryTheme(name: "Archive", roles: [role])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gallery")
        defer { try? FileManager.default.removeItem(at: url) }
        try ThemeFiles.save(theme, to: url)
        expectEqual(try ThemeFiles.load(url), theme)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        expectEqual((object["images"] as! [String: Any]).count, 1)
        expectEqual(object["formatVersion"] as! Int, 2)
    }
    func testUnknownDoesNotPoisonLaterKnownMatch() throws {
        let helper = ImportTests()
        let red = CursorClip(frames: [try helper.frame(.red)], hotX: 4, hotY: 4)
        let blue = CursorClip(frames: [try helper.frame(.blue)], hotX: 4, hotY: 4)
        var matcher = CursorMatcher(); matcher.add(red, role: "arrow")
        expectEqual(matcher.match(red), ["arrow"])
        expectEqual(matcher.match(blue), [])
        expectEqual(matcher.match(red), ["arrow"])
    }
}
