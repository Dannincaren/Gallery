import Foundation
import AppKit
import GalleryCore

final class RegressionTests {
    func testDuplicateFrameOrderAndLimit() throws {
        let red = try ImportTests().frame(.red), blue = try ImportTests().frame(.blue)
        var clip = CursorClip(frames: [red, blue])
        expectEqual(try clip.duplicateFrame(at: 0), 1)
        expectEqual(clip.frames, [red, red, blue])
        expectEqual(clip.duration, 0.15, accuracy: 0.00001)
        expectThrows(try clip.duplicateFrame(at: 8))
        var full = CursorClip(frames: Array(repeating: red, count: 240))
        expectThrows(try full.duplicateFrame(at: 0)); expectEqual(full.frames.count, 240)
    }
    func testRolePresentationArchiveAndLegacyDefaults() throws {
        let clip = CursorClip(frames: [try ImportTests().frame(.red)])
        var role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": clip], scale: 1.4, usesNative: true, sourceThemeName: "Other")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gallery")
        defer { try? FileManager.default.removeItem(at: url) }
        let theme = GalleryTheme(name: "Presentation", roles: [role])
        try ThemeFiles.save(theme, to: url); expectEqual(try ThemeFiles.load(url), theme)
        var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var rows = archive["roles"] as! [[String: Any]]
        for key in ["scale", "usesNative", "sourceThemeName"] { rows[0].removeValue(forKey: key) }
        archive["roles"] = rows
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        role = try ThemeFiles.load(url).roles[0]
        expectEqual(role.scale, 1); expectFalse(role.usesNative); expectEqual(role.sourceThemeName, nil)
    }
    func testMixedRoleTemplatePreservesTargetAndOtherRoles() throws {
        let red = CursorClip(frames: [try ImportTests().frame(.red)]), blue = CursorClip(frames: [try ImportTests().frame(.blue)])
        let arrow = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": red], scale: 1.3, usesNative: true)
        var alias = arrow; alias.id = "com.apple.cursor.0"
        let text = CursorRole(id: "com.apple.coregraphics.IBeam", name: "Text", clips: ["normal": red])
        var theme = GalleryTheme(name: "Mix", roles: [arrow, alias, text])
        let source = CursorRole(id: "com.apple.cursor.19", name: "Different role", clips: ["normal": blue])
        try ThemeLibrary.applyTemplate(source, sourceName: "Other theme", to: arrow.id, in: &theme)
        expectEqual(theme.roles.map(\.id), [arrow.id, alias.id, text.id])
        expectEqual(theme.roles[0].scale, 1.3); expectEqual(theme.roles[0].name, "Arrow")
        expectFalse(theme.roles[0].usesNative); expectEqual(theme.roles[1].clips, source.clips)
        expectEqual(theme.roles[2], text)
    }
    func testThemeDirectoryIndexAndTraversalRejection() throws {
        let role = CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": CursorClip(frames: [try ImportTests().frame(.red)])])
        let theme = GalleryTheme(name: "Folder", roles: [role])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let row = LibraryTheme(theme: theme)
        try ThemeLibrary.saveIndex([row], at: url); expectEqual(try ThemeLibrary.loadIndex(at: url), [row])
        try ThemeLibrary.saveIndex([LibraryTheme(id: "../bad", theme: theme)], at: url)
        expectThrows(try ThemeLibrary.loadIndex(at: url))
    }
    func testDirectBitmapDistinguishesNativeAndApplied() throws {
        let red = CursorClip(frames: [try ImportTests().frame(.red)]), blue = CursorClip(frames: [try ImportTests().frame(.blue)])
        var matcher = CursorMatcher(); matcher.add(red, role: "arrow"); matcher.add(blue, role: "arrow", applied: true)
        let native = matcher.identify(image: try CursorImages.bitmap(red.frames[0]), width: 32, height: 32, hotX: 0, hotY: 0)
        let custom = matcher.identify(image: try CursorImages.bitmap(blue.frames[0]), width: 32, height: 32, hotX: 0, hotY: 0)
        expectEqual(native.roles, ["arrow"]); expectEqual(native.appliedRoles, [])
        expectEqual(custom.appliedRoles, ["arrow"])
    }
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
