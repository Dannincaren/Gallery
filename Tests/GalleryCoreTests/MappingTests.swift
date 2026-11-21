import Foundation
import AppKit
import GalleryCore

final class MappingTests {
    private let text = "com.apple.coregraphics.IBeam", vertical = "com.apple.cursor.26"
    func testImportResetRetainsAliasesDirectionsAndArchiveSnapshot() throws {
        let base = try fixture().roles[0]
        let roles = CursorCatalog.all.filter { !$0.isAssetOnly }.map { descriptor -> CursorRole in
            var role = base; role.id = descriptor.id; role.name = descriptor.title; return role
        }
        let original = GalleryTheme(name: "Complete imported assignments", roles: roles)
        var mapping = ThemeMapping.draft(for: original)
        let imported = mapping.bindings
        expectEqual(imported["com.apple.cursor.2"]?.sourceID, "com.apple.cursor.2")
        expectEqual(imported["com.apple.coregraphics.IBeamXOR"]?.sourceID, text)
        for id in ["com.apple.cursor.17", "com.apple.cursor.18", "com.apple.cursor.19", "com.apple.cursor.27", "com.apple.cursor.38"] {
            expectEqual(imported[id]?.sourceID, "com.apple.cursor.17")
        }
        mapping.bindings = [text: RoleMappingChoice(sourceID: "com.apple.coregraphics.Arrow")]
        let mapped = try mapping.applying(to: original, deleteUnused: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("reset.gallery")
        try ThemeFiles.save(mapped, to: url)
        let restored = ThemeMapping.draft(for: try ThemeFiles.load(url)).restoringImportBindings
        expectEqual(restored.bindings, imported)
        let output = try restored.applying(to: mapped, deleteUnused: false)
        expectEqual(Set(output.roles.map { NativeCursorCatalog.identity($0.id) }), Set(imported.keys))
        var legacy = mapping; legacy.importBindings = nil
        expectEqual(legacy.restoringImportBindings.bindings["com.apple.cursor.18"]?.sourceID, "com.apple.cursor.17")
        let compact = try mapping.applying(to: mapped, deleteUnused: true)
        try compact.mapping!.validate()
        expectEqual(Set(compact.mapping!.restoringImportBindings.bindings.values.map(\.sourceID)), ["com.apple.coregraphics.Arrow"])
    }
    private func fixture() throws -> GalleryTheme {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 2, y: 2, width: 10, height: 10))
        let first = try CursorImages.png(context.makeImage()!)
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
        let second = try CursorImages.png(context.makeImage()!)
        let clip = CursorClip(frames: [first, second], frameDuration: 0.08, width: 32, height: 32, hotX: 4, hotY: 5)
        var role = CursorRole(id: text, name: "文本选择", clips: Dictionary(uniqueKeysWithValues: Motion.allCases.map { ($0.rawValue, clip) }), scale: 1.2, idleDelayOverride: 12)
        var still = clip; still.frames = [second]; still.hotX = 6
        role.variants["normal"] = [CursorVariant(id: "animated", name: "动态", clip: clip), CursorVariant(id: "static", name: "静态", clip: still)]
        role.selectedVariants["normal"] = "animated"
        var alias = role; alias.id = "com.apple.cursor.1"
        var asset = role; asset.id = "com.apple.gallery.Imported.Extra"; asset.name = "Extra"
        return GalleryTheme(name: "Mapping fixture", roles: [role, alias, asset])
    }
    func testIndependentCopiesAndVariantPhases() throws {
        let original = try fixture()
        var mapping = ThemeMapping.draft(for: original)
        expectEqual(mapping.sources.count, 2); expectEqual(mapping.bindings.count, 1)
        let choice = RoleMappingChoice(sourceID: text, normalVariantID: "static")
        mapping.bindings[text] = choice; mapping.bindings[vertical] = choice
        var result = try mapping.applying(to: original, deleteUnused: false)
        let verticalBefore = try require(result.roles.first { $0.id == vertical })
        expectEqual(verticalBefore.clip(.normal)?.frames.count, 1)
        for motion in [Motion.press, .hold, .release, .idle] {
            expectEqual(verticalBefore.clip(motion), original.roles[0].clip(motion))
        }
        let index = try require(result.roles.firstIndex { $0.id == text })
        result.roles[index].scale = 2.1
        result.roles[index].clips["normal"]?.hotX = 9
        result.roles[index].clips["press"]?.frames.reverse()
        result.roles[index].variants["normal"]?[0].clip.hotY = 8
        result.roles[index].idleDelayOverride = 31
        result.roles[index].usesNative = true
        expectEqual(result.roles.first { $0.id == vertical }, verticalBefore)
        expectEqual(result.mapping?.sources, mapping.sources)
        expectEqual(original.roles[0].scale, 1.2)
        // Reopening and completing a draft must retain destination-only edits.
        let reopened = try ThemeMapping.draft(for: result).applying(to: result, deleteUnused: false)
        expectEqual(reopened.roles, result.roles)
        expectEqual(Set(result.roles.map(\.id)).count, result.roles.count)
    }
    func testUnusedDeletionAndPortablePool() throws {
        let original = try fixture()
        let mapping = ThemeMapping.draft(for: original)
        let retained = try mapping.applying(to: original, deleteUnused: false)
        let removed = try mapping.applying(to: retained, deleteUnused: true)
        expectEqual(retained.mapping?.sources.count, 2); expectEqual(removed.mapping?.sources.count, 1)
        expectEqual(removed.roles, retained.roles)
        expectEqual(original.roles.count, 3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("portable.gallery")
        try ThemeFiles.save(retained, to: url)
        expectEqual(try ThemeFiles.load(url), retained)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        expectEqual((json["images"] as? [String: Any])?.count, 2)
        // A retained, unused source receives the same image validation as a
        // runtime role, before it can be selected for a future binding.
        var invalid = retained
        invalid.mapping?.sources[1].clips["normal"]?.frames = [Data([1, 2, 3])]
        try ThemeFiles.save(invalid, to: url); expectThrows(try ThemeFiles.load(url))
    }
    func testReplaceRemoveAndInvalidReferences() throws {
        let original = try fixture()
        var mapping = ThemeMapping.draft(for: original)
        mapping.bindings[vertical] = RoleMappingChoice(sourceID: original.roles[2].id)
        let first = try mapping.applying(to: original, deleteUnused: false)
        mapping.bindings[vertical] = RoleMappingChoice(sourceID: text, normalVariantID: "static")
        let second = try mapping.applying(to: first, deleteUnused: false)
        expectEqual(second.roles.first { $0.id == vertical }?.clip(.normal)?.frames.count, 1)
        mapping.bindings.removeValue(forKey: vertical)
        let third = try mapping.applying(to: second, deleteUnused: false)
        expectFalse(third.roles.contains { $0.id == vertical })
        mapping.bindings[vertical] = RoleMappingChoice(sourceID: "missing")
        expectThrows(try mapping.validate())
        mapping.bindings[vertical] = RoleMappingChoice(sourceID: text, normalVariantID: "missing")
        expectThrows(try mapping.validate())
        mapping.bindings.removeValue(forKey: vertical)
        mapping.bindings["com.apple.gallery.Imported.Extra"] = RoleMappingChoice(sourceID: text)
        expectThrows(try mapping.validate())
        mapping.bindings.removeAll(); expectThrows(try mapping.applying(to: original, deleteUnused: false))
        mapping = ThemeMapping.draft(for: original); mapping.sources.append(mapping.sources[0]); expectThrows(try mapping.validate())
        let legacy = try JSONDecoder().decode(GalleryTheme.self, from: JSONEncoder().encode(original))
        expectEqual(legacy.mapping, nil); expectEqual(legacy, original)
    }
    func testStableAlignmentAndExpandedBounds() throws {
        let theme = try fixture()
        var mapping = ThemeMapping.draft(for: theme)
        let ids = ThemeMapping.nativeRoles.map(\.id)
        mapping.bindings[vertical] = RoleMappingChoice(sourceID: theme.roles[2].id)
        let slots = MappingLayout.sourceSlots(mapping)
        expectEqual(slots[text], Double(try require(ids.firstIndex(of: text))) * 204)
        expectEqual(slots[theme.roles[2].id], Double(try require(ids.firstIndex(of: vertical))) * 204)
        let expanded = MappingLayout.sourceSlots(mapping, heights: [text: 600])
        expectFalse(try require(expanded[theme.roles[2].id]) < require(expanded[text]) + 628)
        var reversed = mapping
        reversed.bindings = Dictionary(uniqueKeysWithValues: mapping.bindings.sorted { $0.key > $1.key }.map { ($0.key, $0.value) })
        expectEqual(MappingLayout.sourceSlots(reversed), slots)
        // A removed connection stays in the local layout, not below all 46
        // native cards. The next bound source retains its original alignment.
        mapping.bindings.removeValue(forKey: vertical)
        expectEqual(MappingLayout.sourceSlots(mapping, previous: slots), slots)
        expectEqual(ThemeMapping.nativeRoles.map(\.id), ids)
        expectEqual(Set(ids).count, ids.count)
        expectFalse(ThemeMapping.nativeRoles.contains { $0.isAssetOnly })
        // Collision is resolved on BOTH sides, rather than pushing a long
        // chain of later cards downwards. No cards may overlap.
        let crowded = ThemeMapping(sources: mapping.sources, bindings: [ids[10]: RoleMappingChoice(sourceID: text), ids[11]: RoleMappingChoice(sourceID: theme.roles[2].id)])
        let crowdedSlots = MappingLayout.sourceSlots(crowded, spacing: 300)
        expectEqual(crowdedSlots[text], 3000)
        expectEqual(crowdedSlots[theme.roles[2].id], 3300)
    }
    func testDetailedNativeDestinationsAndMigration() throws {
        let theme = try fixture()
        let legacy = ThemeMapping(sources: [theme.roles[0], theme.roles[2]], bindings: [text: RoleMappingChoice(sourceID: text)], detailedNativeRoles: false)
        var old = theme; old.mapping = legacy
        let migrated = ThemeMapping.draft(for: old)
        expectEqual(migrated.detailedNativeRoles, true)
        expectEqual(migrated.sources, legacy.sources)
        expectEqual(migrated.bindings[text], legacy.bindings[text])
        expectEqual(migrated.bindings["com.apple.coregraphics.IBeamXOR"], legacy.bindings[text])
        let ids = Set(ThemeMapping.nativeRoles.flatMap { NativeCursorCatalog.identifiers(for: $0.id) })
        for n in 0...43 where n != 6 { expectEqual(ids.contains("com.apple.cursor.\(n)"), true) }
        var detailed = migrated
        for id in ["com.apple.cursor.11", "com.apple.cursor.12", "com.apple.cursor.17", "com.apple.cursor.18", "com.apple.cursor.27", "com.apple.cursor.38", "com.apple.cursor.2", "com.apple.cursor.13"] {
            detailed.bindings[id] = RoleMappingChoice(sourceID: text)
        }
        let result = try detailed.applying(to: old, deleteUnused: false)
        expectFalse(result.roleFamily("com.apple.cursor.11") == result.roleFamily("com.apple.cursor.12"))
        expectFalse(result.roleFamily("com.apple.cursor.17") == result.roleFamily("com.apple.cursor.18"))
        expectFalse(result.roleFamily("com.apple.cursor.2") == result.roleFamily("com.apple.cursor.13"))
        expectEqual(result.roleFamily(text), result.roleFamily("com.apple.cursor.1"))
        expectEqual(LibraryTheme(theme: result).roles.count, result.mapping!.bindings.count)
        let data = try JSONEncoder().encode(result)
        expectEqual(try JSONDecoder().decode(GalleryTheme.self, from: data), result)
        var legacyAliases = theme.roles[0]; legacyAliases.id = "com.apple.coregraphics.Alias"; legacyAliases.scale = 2.5
        var legacyLink = theme.roles[0]; legacyLink.id = "com.apple.cursor.2"; legacyLink.scale = 0.8
        let mixed = GalleryTheme(name: "Legacy alias normalization", roles: [legacyLink, legacyAliases])
        let normalized = try ThemeMapping.draft(for: mixed).applying(to: mixed, deleteUnused: false)
        expectEqual(normalized.roles.first { $0.id == "com.apple.cursor.2" }?.scale, 0.8)
        expectEqual(normalized.roles.first { $0.id == "com.apple.coregraphics.Alias" }?.scale, 0.8)
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        legacyJSON.removeValue(forKey: "detailedNativeRoles")
        expectFalse(try JSONDecoder().decode(ThemeMapping.self, from: JSONSerialization.data(withJSONObject: legacyJSON)).detailedNativeRoles)
    }
    func testTwoSidedPlacementRemovesCrossings() throws {
        let theme = try fixture(), ids = ThemeMapping.nativeRoles.map(\.id)
        let sources = [theme.roles[0], theme.roles[2]]
        var mapping = ThemeMapping(sources: sources, bindings: [:])
        for (index, row) in [4, 8, 12, 16, 20, 24].enumerated() {
            mapping.bindings[ids[row]] = RoleMappingChoice(sourceID: sources[index % 2].id)
        }
        let first = MappingLayout.sourceSlots(mapping)
        let layout = MappingLayout.arrangement(mapping)
        expectFalse(layout.natives[ids[12]] == 12 * 204) // Left cards may move.
        expectFalse(layout.sources == [:])
        let sourceOrder = sources.sorted { first[$0.id]! < first[$1.id]! }.map(\.id)
        let ordered = ids.filter { mapping.bindings[$0] != nil }.sorted { layout.natives[$0]! < layout.natives[$1]! }
        expectEqual(ordered.map { mapping.bindings[$0]!.sourceID }, [sourceOrder[0], sourceOrder[0], sourceOrder[0], sourceOrder[1], sourceOrder[1], sourceOrder[1]])
        // Unbound roles stay in their original slots. Members of one source
        // retain system order, so grouping introduces no arbitrary shuffles.
        for (index, id) in ids.enumerated() where mapping.bindings[id] == nil { expectEqual(layout.natives[id], Double(index) * 204) }
        for source in sources {
            expectEqual(ordered.filter { mapping.bindings[$0]?.sourceID == source.id }, ids.filter { mapping.bindings[$0]?.sourceID == source.id })
        }
        expectEqual(MappingLayout.arrangement(mapping), layout)
        mapping.bindings.removeAll()
        let reset = MappingLayout.arrangement(mapping, previous: layout.sources)
        for (index, id) in ids.enumerated() { expectEqual(reset.natives[id], Double(index) * 204) }
    }
    func testTwoSidedPlacementStaysOrderedDuringBindingChanges() throws {
        let theme = try fixture(), ids = ThemeMapping.nativeRoles.map(\.id)
        var sources = [theme.roles[0], theme.roles[2]]
        var extra = sources[0]; extra.id = "com.apple.gallery.LayoutExtra"; sources.append(extra)
        var mapping = ThemeMapping(sources: sources, bindings: [:])
        var previous: [String: Double] = [:]
        for iteration in 0..<64 {
            for (index, id) in ids.enumerated() {
                if (index * 13 + iteration) % 7 == 0 { mapping.bindings.removeValue(forKey: id) }
                else { mapping.bindings[id] = RoleMappingChoice(sourceID: sources[(index * 7 + iteration / 3) % sources.count].id) }
            }
            let layout = MappingLayout.arrangement(mapping, previous: previous)
            let order = ids.filter { mapping.bindings[$0] != nil }.sorted { layout.natives[$0]! < layout.natives[$1]! }
            let sourceYs = order.map { layout.sources[mapping.bindings[$0]!.sourceID]! }
            expectEqual(sourceYs, sourceYs.sorted()) // No crossed connections.
            let leftYs = layout.natives.values.sorted(), rightYs = layout.sources.values.sorted()
            for ys in [leftYs, rightYs] { for pair in zip(ys, ys.dropFirst()) { expectFalse(pair.1 - pair.0 < 204) } }
            expectEqual(MappingLayout.arrangement(mapping, previous: previous), layout)
            previous = layout.sources
        }
    }
    func testDeletionActuallyCompactsLocalArchive() throws {
        var theme = try fixture()
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let unused = try CursorImages.png(context.makeImage()!)
        theme.roles[2].clips = ["normal": CursorClip(frames: [unused])]
        theme.roles[2].variants = [:]; theme.roles[2].selectedVariants = [:]
        let mapping = ThemeMapping.draft(for: theme)
        let kept = try mapping.applying(to: theme, deleteUnused: false)
        let deleted = try mapping.applying(to: kept, deleteUnused: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = root.appendingPathComponent("import.gallery"), stored = root.appendingPathComponent("local.gallery")
        try ThemeFiles.save(kept, to: imported); try ThemeFiles.save(kept, to: stored)
        let original = try Data(contentsOf: imported), before = try Data(contentsOf: stored)
        try ThemeFiles.save(deleted, to: stored)
        let after = try Data(contentsOf: stored)
        let archive = try JSONSerialization.jsonObject(with: after) as! [String: Any]
        expectGreater(before.count, after.count)
        expectEqual((archive["images"] as? [String: Any])?.count, 2)
        expectEqual(try Data(contentsOf: imported), original)
        expectEqual(try ThemeFiles.load(stored), deleted)
        expectEqual(deleted.roles, kept.roles)
    }
    func testFullVariantShelfKeepsOriginalWithoutOverflow() throws {
        var theme = try fixture()
        var source = theme.roles[0]
        var still = source.clip(.normal)!; still.frames = [still.frames[0]]
        source.variants["normal"] = (0..<32).map { CursorVariant(id: "v\($0)", name: "Variant \($0)", clip: still) }
        source.selectedVariants.removeValue(forKey: "normal")
        theme.roles = [source]
        var mapping = ThemeMapping.draft(for: theme)
        mapping.bindings[text] = RoleMappingChoice(sourceID: text, normalVariantID: "v31")
        let result = try mapping.applying(to: theme, deleteUnused: false)
        expectEqual(result.roles[0].variants["normal"]?.count, 32)
        expectEqual(result.roles[0].clip(.normal)?.frames.count, 1)
        expectEqual(result.mapping?.sources[0].clip(.normal)?.frames.count, 2)
        expectEqual(source.clip(.normal)?.frames.count, 2)
    }
}
