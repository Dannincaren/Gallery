import AppKit
import GalleryCore

@main @MainActor
struct MappingHarness {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ThemeError.invalid(message) }
    }
    static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-mapping-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let text = "com.apple.coregraphics.IBeam", vertical = "com.apple.cursor.26"
            var theme = Demo.makeTheme()
            var source = theme.roles.first { $0.id == text }!
            var alternate = source.clip(.normal)!; alternate.hotX = 3
            source.variants["normal"] = [CursorVariant(id: "alternate", name: "Alternate", clip: alternate)]
            theme.roles = [source]
            let folder = root.appendingPathComponent("Themes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let row = LibraryTheme(theme: theme)
            var otherTheme = theme; otherTheme.name = "Independent mapping"
            let otherRow = LibraryTheme(theme: otherTheme)
            try ThemeFiles.save(theme, to: folder.appendingPathComponent(row.id + ".gallery"))
            try ThemeFiles.save(otherTheme, to: folder.appendingPathComponent(otherRow.id + ".gallery"))
            try ThemeLibrary.saveIndex([row, otherRow], at: root.appendingPathComponent("themes.json"))
            let store = GalleryStore(rootURL: root)
            let draft = ThemeMappingDraft(theme: theme), choice = RoleMappingChoice(sourceID: text)
            draft.bind(choice, to: vertical)
            try check(draft.hasChanges, "Mapping draft did not record a binding")
            let mappingBeforeFocus = draft.mapping
            draft.focus(text)
            let firstRequest = draft.focusRequest
            draft.focus(text)
            try check(draft.focusRequest?.sourceID == text && draft.focusRequest != firstRequest, "Repeated sidebar focus request was lost")
            let validRequest = draft.focusRequest
            draft.focus("missing-source")
            try check(draft.focusRequest == validRequest && draft.mapping == mappingBeforeFocus, "Invalid focus changed the draft")
            var selection = MappingSelection()
            try check(selection.selectSource(choice) == nil && selection.source == choice && selection.native == nil, "Source-first selection failed")
            try check(selection.selectNative(vertical) == choice && selection.native == nil && selection.source == nil, "Pairing did not consume selection")
            _ = selection.selectNative(vertical)
            try check(selection.native == vertical && selection.source == nil, "Native selection highlighted both sides")
            _ = selection.selectNative(vertical)
            try check(selection.native == nil && selection.source == nil, "Native second-click did not deselect")
            _ = selection.selectSource(choice); _ = selection.selectSource(choice)
            try check(selection.native == nil && selection.source == nil, "Source second-click did not deselect")
            _ = selection.selectNative(vertical)
            try check(selection.selectSource(choice) == vertical && selection.native == nil && selection.source == nil, "Native-first pairing did not clear selection")
            let changedMapping = draft.mapping
            try check(draft.canUndo, "Binding did not enable undo")
            draft.undo()
            try check(draft.mapping == draft.initial && !draft.canUndo, "Undo did not restore the initial binding")
            draft.bind(choice, to: vertical)
            draft.restoreImportDefaults()
            try check(draft.mapping == draft.importDefaults, "Import reset used current edited destinations")
            draft.undo()
            try check(draft.mapping == changedMapping, "Import reset could not be undone")
            try check(MappingSavePrompt.first(for: draft.mapping) == .native, "Unpaired roles did not receive the first confirmation")
            try check(MappingSavePrompt.afterNative(for: draft.mapping) == nil, "Fully-used materials asked for deletion")
            var all = draft.mapping
            all.bindings = Dictionary(uniqueKeysWithValues: ThemeMapping.nativeRoles.map { ($0.id, choice) })
            try check(MappingSavePrompt.first(for: all) == nil, "Fully paired and used mapping did not save directly")
            var spare = source; spare.id = "com.apple.gallery.Spare"; all.sources.append(spare)
            try check(MappingSavePrompt.first(for: all) == .unused && MappingSavePrompt.afterNative(for: all) == .unused, "Unused-material confirmation was missing")
            all.bindings.removeValue(forKey: vertical)
            try check(MappingSavePrompt.first(for: all) == .native, "Unused-material prompt came before native-role prompt")
            try store.applyMapping(draft.mapping, to: row.id, deleteUnused: false)
            let groups = store.theme.editorRoleGroups
            try check(groups.count == 1 && groups[0].source.name == source.name && Set(groups[0].destinations.map(\.id)) == Set([text, vertical]),
                      "Sidebar duplicated a source or lost its imported name / independent destinations")
            var kept = store.theme
            var extra = source; extra.id = "com.apple.gallery.Unbound"; extra.name = "Retained source"
            kept.mapping?.sources.append(extra)
            try check(kept.editorRoleGroups.last?.source.name == "Retained source" && kept.editorRoleGroups.last?.destinations.isEmpty == true,
                      "Sidebar lost an unassigned source")
            let untouched = store.theme.roles.first { $0.id == vertical }!
            store.selectedRole = text; store.selectedMotion = .normal
            store.setRoleScale(1.65); store.setRoleIdleDelay(43, for: text)
            store.edit { $0.hotX = 7; $0.frameDuration = 0.19 }
            store.selectVariant("alternate", for: .normal)
            store.selectedMotion = .press
            store.edit { $0.frames.reverse(); $0.hotY = 7 }
            store.selectedMotion = .hold; store.removeClip()
            store.setUsesNative(true)
            try check(store.theme.roles.first { $0.id == vertical } == untouched,
                      "Changing text size, hotspot, idle, phase, variant or native mode changed vertical text")
            let aliases = store.theme.roles.filter { store.theme.roleFamily($0.id) == text }
            try check(aliases.count > 1 && aliases.allSatisfy { $0.scale == 1.65 && $0.usesNative && $0.clip(.hold) == nil }, "True system aliases stopped syncing")
            store.saveNow(wait: true)
            let reopened = GalleryStore(rootURL: root)
            try check(reopened.theme.roles.first { $0.id == vertical } == untouched && reopened.theme.mapping == draft.mapping,
                      "Mapped copies or the material shelf did not persist")
            print("PASS mapping selection, save-confirmation order, independent horizontal/vertical text edits, aliases and saved sources")
            var precise = ThemeMapping.draft(for: store.theme)
            for id in ["com.apple.cursor.17", "com.apple.cursor.18", "com.apple.cursor.11", "com.apple.cursor.12", "com.apple.cursor.2", "com.apple.cursor.13"] {
                precise.bindings[id] = choice
            }
            try store.applyMapping(precise, to: row.id, deleteUnused: false)
            for (left, right) in [("com.apple.cursor.17", "com.apple.cursor.18"), ("com.apple.cursor.11", "com.apple.cursor.12"), ("com.apple.cursor.2", "com.apple.cursor.13")] {
                let untouched = store.theme.roles.first { $0.id == right }!
                store.selectedRole = left; store.selectedMotion = .normal
                store.setRoleScale(2.25); store.setRoleIdleDelay(55, for: left)
                store.edit { $0.hotY = 9 }; store.setUsesNative(true)
                try check(store.theme.roles.first { $0.id == right } == untouched, "Detailed native roles still share size or animation edits")
            }
            try check(store.visibleRoles.count == precise.bindings.count, "Detailed native roles were hidden by semantic grouping")
            print("PASS independent directional resize, open/closed hands and drag-link/pointing-hand edits")
            let before = store.theme
            var rejected = false
            do { try store.applyMapping(precise, to: "stale", deleteUnused: true) }
            catch { rejected = true }
            try check(rejected && store.theme == before, "Accepted a stale mapping window")
            let sessionID = UUID()
            try check(store.beginMappingEditor(sessionID), "Inactive theme did not allow entering mapping")
            store.applyCurrentTheme()
            try check(!store.runtime.enabled, "Theme activated while mapping was being edited")
            store.endMappingEditor(sessionID)
            store.applyCurrentTheme()
            try check(store.editingActiveTheme, "Runtime spy did not enable active-theme lock")
            try check(!store.canEditMapping && !store.beginMappingEditor(UUID()), "Active theme still opened a mapping editor")
            store.stopTheme()
            try check(store.runtime.enabled && store.switchingTheme, "Repeated stop bypassed the four-second activation gate")
            rejected = false
            do { try store.applyMapping(precise, to: row.id, deleteUnused: false) }
            catch { rejected = true }
            try check(rejected && store.theme == before, "Accepted active-theme mapping edit")
            store.saveNow(wait: true)
            let activeArchive = try Data(contentsOf: folder.appendingPathComponent(row.id + ".gallery"))
            let starts = store.runtime.starts.count
            store.selectTheme(otherRow.id)
            let deadline = Date().addingTimeInterval(5)
            while store.importing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(!store.importing && store.selectedThemeID == otherRow.id, "Could not browse the other theme")
            try check(store.runtime.enabled && store.activeThemeID == row.id && store.canEditMapping,
                      "Running theme disabled another theme's independent mapping editor")
            let otherSession = UUID()
            try check(store.beginMappingEditor(otherSession), "Another theme's mapping editor was still locked")
            var otherMapping = ThemeMapping.draft(for: store.theme)
            otherMapping.bindings[vertical] = choice
            try store.applyMapping(otherMapping, to: otherRow.id, deleteUnused: false)
            store.saveNow(wait: true); store.endMappingEditor(otherSession)
            try check(store.runtime.enabled && store.activeThemeID == row.id && store.runtime.starts.count == starts
                      && (try Data(contentsOf: folder.appendingPathComponent(row.id + ".gallery"))) == activeArchive,
                      "Editing another theme restarted or changed the active theme")
            print("PASS another theme's mapping remains editable and saves without changing the running theme")
            store.runtime.stop()
            try check(!store.runtime.enabled, "Internal restoration was blocked by the user cooldown")
            print("PASS stale-window and active-theme protection; no global cursor writes")
            let cache = MappingFrameCache(), clip = source.clip(.normal)!, png = clip.frames[0]
            let sharp = await cache.image(png, clip: clip, appearance: CursorAppearance(smoothEdges: false))
            let pixel = await cache.image(png, clip: clip, appearance: CursorAppearance(pixelArt: true))
            let smooth = await cache.image(png, clip: clip, appearance: CursorAppearance())
            let shadow = await cache.image(png, clip: clip, appearance: CursorAppearance(shadow: true))
            try check(sharp != nil && sharp === pixel && sharp !== smooth && shadow != nil && shadow!.width > sharp!.width,
                      "Mapping previews ignored pixel rules or shadow")
            for index in 0..<140 {
                let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(NSColor(hue: Double(index) / 140, saturation: 1, brightness: 1, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                _ = await cache.image(try CursorImages.png(context.makeImage()!), clip: clip, appearance: CursorAppearance())
            }
            let usage = await cache.footprint()
            try check(usage.count <= 128 && usage.bytes <= 24 * 1024 * 1024, "Mapping cache exceeded its budget")
            await cache.clear(); try check(await cache.footprint().count == 0, "Mapping cache did not release frames")
            print("PASS shared mapping raster cache, sharp/pixel parity, shadow, hard budget and release")
            let nativeURL = URL(fileURLWithPath: "Resources/NativeCursorPreviews.plist")
            let native = await NativeMappingArtwork.load(from: nativeURL)
            try check(native[text] != nil && native[vertical] != nil && native.count == ThemeMapping.nativeRoles.count,
                      "Missing common native preview artwork")
            let cacheURL = root.appendingPathComponent("native-cache/previews.plist")
            let systemResources = URL(fileURLWithPath: "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors")
            let built = await NativeMappingArtwork.load(fallback: nativeURL, resources: systemResources, cache: cacheURL, system: "TestOS-1")
            let emptyResources = root.appendingPathComponent("no-system-files")
            let hit = await NativeMappingArtwork.load(fallback: nativeURL, resources: emptyResources, cache: cacheURL, system: "TestOS-1")
            try check(built == native && hit == built, "Generated original cache was not reused")
            let refreshed = await NativeMappingArtwork.load(fallback: nativeURL, resources: emptyResources, cache: cacheURL, system: "TestOS-2")
            try check(refreshed.count == native.count && refreshed[text] != native[text], "System upgrade did not invalidate cache or bundled fallback was missing")
            try Data("invalid".utf8).write(to: cacheURL)
            let repaired = await NativeMappingArtwork.load(fallback: nativeURL, resources: systemResources, cache: cacheURL, system: "TestOS-2")
            try check(repaired == native, "Corrupted cache did not rebuild safely")
            var damaged = try PropertyListSerialization.propertyList(from: Data(contentsOf: cacheURL), format: nil) as! [String: Any]
            var cachedClips = damaged["clips"] as! [String: Any]
            var cachedText = cachedClips[text] as! [String: Any]
            cachedText["frames"] = [Data("broken PNG".utf8)]; cachedClips[text] = cachedText; damaged["clips"] = cachedClips
            try PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0).write(to: cacheURL)
            let repairedImage = await NativeMappingArtwork.load(fallback: nativeURL, resources: systemResources, cache: cacheURL, system: "TestOS-2")
            try check(repairedImage == native, "Valid cache metadata hid a broken preview image")
            print("PASS local OS files + complete compatibility fallback: \(native.count) roles; cache hit, OS invalidation and corrupt-header/image rebuild")
            let area = CGSize(width: 84, height: 84)
            var rowSizes: [CGSize] = [], columnSizes: [CGSize] = []
            for (ids, row) in [(["com.apple.cursor.21", "com.apple.cursor.22", "com.apple.cursor.23"], true), (["com.apple.cursor.17", "com.apple.cursor.18", "com.apple.cursor.19"], false)] {
                for id in ids {
                    guard let clip = native[id], let data = clip.frames.first else { throw ThemeError.invalid("Missing native resize fixture") }
                    let image = try CursorImages.bitmap(data)
                    let size = MappingPreviewSizing.size(mode: .nativeMode(id: id, clips: native),
                        image: CGSize(width: image.width, height: image.height), available: area)
                    if row { rowSizes.append(size) } else { columnSizes.append(size) }
                }
            }
            try check(rowSizes.allSatisfy { abs($0.width - rowSizes[0].width) < 0.01 && $0.height <= 73 }, "Row-resize bars changed size between one-way and two-way cursors")
            try check(columnSizes.allSatisfy { abs($0.height - columnSizes[0].height) < 0.01 && $0.width <= 73 }, "Column-resize bars changed size between one-way and two-way cursors")
            print("PASS real system row/column variants share their crossbar size and fit the preview square")
            // A theme's journal and current registered images must never
            // supply display-only original system artwork.
            let recovery = root.appendingPathComponent("native-preview.plist")
            let dictionary = try CursorImages.capeDictionary(clip)
            try PropertyListSerialization.data(fromPropertyList: ["com.apple.coregraphics.Arrow": dictionary], format: .binary, options: 0).write(to: recovery)
            let rejectedArtwork = await NativeMappingArtwork.load(from: recovery)
            let missing = await NativeMappingArtwork.load(from: root.appendingPathComponent("missing.plist"))
            let repeated = await NativeMappingArtwork.load(from: nativeURL)
            try check(rejectedArtwork.isEmpty && missing.isEmpty && repeated == native,
                      "Native previews accepted theme recovery artwork or changed between loads")
            try check(native["com.apple.coregraphics.Wait"]?.frames.count == 30 && native["com.apple.cursor.39"]?.frames.count == 1,
                      "Native originals were replaced or their animation was sampled")
            let textImage = try CursorImages.bitmap(native[text]!.frames[0])
            let verticalImage = try CursorImages.bitmap(native[vertical]!.frames[0])
            try check(max(textImage.width, textImage.height) == 192, "Bundled system artwork did not retain Retina preview resolution")
            try check(textImage.height > textImage.width && verticalImage.width > verticalImage.height,
                      "System text-layout resource names were confused with the cursor's orientation")
            print("PASS bundled Retina originals ignore theme journals and missing files; all native animation frames retained")
            try checkImmediateLineInputAndSizing()
            print("PASS immediate line clicks, same-line double-click unlink, card hit exclusion and uniform / adaptive preview size")
            try checkBundledArtwork(native)
            try await checkCenteredArtwork()
            print("PASS fixed native artwork centering and stable adaptive theme animation canvas")
            try await checkScrollViewport()
            print("PASS hidden scroll viewport follows top, deep scroll, resize and return without opening a window")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
    static func checkImmediateLineInputAndSizing() throws {
        var clicks = MappingLineClicks()
        let point = CGPoint(x: 300, y: 100)
        try check(clicks.down(line: "a", count: 1, point: point, time: 1, interval: 0.5) == .select("a"), "Single click waited for a second click")
        try check(clicks.down(line: "a", count: 2, point: point, time: 1.1, interval: 0.5) == .disconnect("a"), "Consecutive double click did not unlink")
        _ = clicks.down(line: "a", count: 1, point: point, time: 2, interval: 0.5)
        try check(clicks.down(line: "b", count: 2, point: point, time: 2.1, interval: 0.5) == .select("b"), "Clicking another crossing line unlinked it")
        try check(clicks.down(line: nil, count: 1, point: point, time: 3, interval: 0.5) == .select(nil), "Blank click did not deselect")
        try check(clicks.down(line: "b", count: 2, point: point, time: 3.1, interval: 0.5) == .select("b"), "Blank click failed to end double click sequence")
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 760))
        let view = MappingBoardInputView(frame: parent.bounds); parent.addSubview(view)
        view.configure(cards: [CGRect(x: 35, y: 20, width: 160, height: 160)], lines: [], selected: nil, action: { _ in })
        let inside = parent.convert(NSPoint(x: 100, y: 100), from: view)
        let blank = parent.convert(NSPoint(x: 350, y: 100), from: view)
        try check(view.hitTest(inside) == nil && view.hitTest(blank) == nil && !view.consumesMouseDown(at: CGPoint(x: 100, y: 100)) && view.consumesMouseDown(at: CGPoint(x: 350, y: 100)), "Line input stole a card's first click or missed the background")
        let area = CGSize(width: 84, height: 84)
        let h = MappingPreviewSizing.size(mode: .native, image: CGSize(width: 256, height: 107), available: area)
        let v = MappingPreviewSizing.size(mode: .native, image: CGSize(width: 107, height: 256), available: area)
        try check(h.width == v.height && h.height == v.width && h.width == 72, "Native cursor size changed with its orientation")
        let small = MappingPreviewSizing.size(mode: .material, image: CGSize(width: 16, height: 16), available: area)
        let normal = MappingPreviewSizing.size(mode: .material, image: CGSize(width: 96, height: 96), available: area)
        let large = MappingPreviewSizing.size(mode: .material, image: CGSize(width: 512, height: 256), available: area)
        try check(small.width == 72 && normal.width == 72 && large.width == 72 && large.height == 36, "Material sizing did not adapt independently to its visible image")
        let grouped = MappingScaleGroups.smaller(["small": 1.25, "near": 1.27, "next": 1.29, "edge": 1.275,
                                                  "zero": 0, "invalid": .nan, "infinite": .infinity])
        try check(grouped == ["small": 1.25, "near": 1.25, "edge": 1.25, "next": 1.29],
                  "Nearby scales were not lowered together, chained too far, or accepted invalid values")
    }
    static func checkBundledArtwork(_ clips: [String: CursorClip]) throws {
        for (id, clip) in clips {
            let images = try clip.frames.map(CursorImages.bitmap)
            guard let first = images.first else { throw ThemeError.invalid("Missing bundled frame: " + id) }
            try check(images.allSatisfy { $0.width == first.width && $0.height == first.height && max($0.width, $0.height) <= 192 },
                      "Bundled animation has unstable or oversized canvases: " + id)
            var union = CGRect.null
            for image in images {
                guard let bounds = MappingVisiblePixels.bounds(image) else { throw ThemeError.invalid("Empty bundled glyph: " + id) }
                union = union.union(bounds)
            }
            try check(abs(union.midX - Double(first.width) / 2) <= 3 && abs(union.midY - Double(first.height) / 2) <= 3,
                      "Bundled glyph is not centered: " + id)
        }
    }
    static func checkCenteredArtwork() async throws {
        func frame(x: Int) throws -> Data {
            var pixels = [UInt8](repeating: 0, count: 80 * 64 * 4)
            for y in 7..<15 { for col in x..<(x + 12) {
                let i = (y * 80 + col) * 4; pixels[i] = 255; pixels[i + 3] = 255
            } }
            let image = CGImage(width: 80, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 320,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            return try CursorImages.png(image)
        }
        let source = CursorClip(frames: [try frame(x: 32), try frame(x: 40)], frameDuration: 0.09, width: 80, height: 64, hotX: 36, hotY: 10)
        let cache = MappingFrameCache()
        guard let bounds = await cache.canvas(source, appearance: CursorAppearance()) else { throw ThemeError.invalid("Missing adaptive material bounds") }
        try check(abs(bounds.minX - 0.39) < 0.001 && abs(bounds.width - 0.27) < 0.001,
                  "Adaptive preview did not use the union of both moving frames")
        try check(source.frames.count == 2 && source.frameDuration == 0.09 && source.width == 80,
                  "Adapting a preview changed its original animation or canvas")
        let cached = await cache.canvas(source, appearance: CursorAppearance())
        try check(cached == bounds, "Adaptive bounds were unstable between frames")
        let assets = [1.25, 1.27, 1.30].enumerated().map { index, factor -> MappingMaterialAsset in
            var clip = source
            // Use identical raster pixels with different logical point sizes.
            // Grouping pixel-space fit factors would incorrectly merge all three.
            clip.width = 28 / (bounds.width * factor); clip.height = clip.width * 0.8
            return MappingMaterialAsset(id: String(index), clip: clip)
        }
        let presented = await cache.materials(assets, appearance: CursorAppearance(), available: CGSize(width: 40, height: 84))
        try check(abs((presented["0"]?.factor ?? 0) - 1.25) < 0.001 && presented["0"]?.factor == presented["1"]?.factor
                  && abs((presented["2"]?.factor ?? 0) - 1.30) < 0.001,
                  "Theme material presentation did not group scales in logical point units")
        try check(presented.values.allSatisfy { $0.size.width <= 28.001 && $0.size.height <= 72.001 },
                  "Scale normalization enlarged a preview beyond its available stage")
        try check(presented["1"]?.clip == assets[1].clip, "Normalizing display scale mutated the source animation")
        await cache.clear()
    }
    static func checkScrollViewport() async throws {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let early = MappingViewportProbe(frame: .zero)
        early.follow(MappingScrollRequest(centerY: 3200, animated: false))
        try await Task.sleep(for: .milliseconds(20))
        let earlyScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 780, height: 600))
        let earlyDoc = Document(frame: NSRect(x: 0, y: 0, width: 780, height: 10000))
        earlyDoc.addSubview(early); earlyScroll.documentView = earlyDoc
        var earlyRect = CGRect.zero; early.changed = { earlyRect = $0 }
        try await Task.sleep(for: .milliseconds(50))
        try check(abs(earlyRect.midY - 3200) < 1, "Sidebar navigation was lost before the new window attached")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 780, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 780, height: 10000))
        let probe = MappingViewportProbe(frame: .zero)
        var observed = CGRect.zero
        probe.changed = { observed = $0 }
        document.addSubview(probe); scroll.documentView = document
        try await Task.sleep(for: .milliseconds(30))
        try check(observed.minY == 0 && observed.height > 500, "Initial viewport was not captured")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 4800)); scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(30))
        try check(observed.minY == 4800, "Deep-scroll viewport remained on the first screen")
        scroll.frame.size.height = 420; scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        try check(observed.height <= 420 && observed.height > 300, "Viewport ignored resize")
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(30))
        try check(observed.minY == 0, "Viewport did not return to the top")
        var samples: [Double] = []
        probe.changed = { observed = $0; samples.append($0.minY) }
        probe.follow(MappingScrollRequest(centerY: 8000, animated: true))
        try await Task.sleep(for: .milliseconds(760))
        try check(abs(observed.midY - 8000) < 1 && samples.count > 8 && samples == samples.sorted(), "Smooth follow skipped, overshot or reversed")
        probe.follow(MappingScrollRequest(centerY: 600, animated: true))
        try await Task.sleep(for: .milliseconds(80))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let stopped = observed.minY
        try await Task.sleep(for: .milliseconds(120))
        try check(observed.minY == stopped, "Automatic follow fought manual scrolling")
        probe.follow(MappingScrollRequest(centerY: 500, animated: false))
        try await Task.sleep(for: .milliseconds(30))
        try check(abs(observed.midY - 500) < 1, "Reduced-motion follow ignored destination")

    }
}
