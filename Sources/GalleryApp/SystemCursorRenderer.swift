import AppKit
import GalleryCore
import GalleryNative

/// The WindowServer owns cursor position, Spaces and visibility. Gallery only
/// submits cached images. This renderer never hides the cursor or moves a window.
@MainActor
final class SystemCursorRenderer {
    private struct Key: Hashable {
        let role: String, motion: Motion, image: ObjectIdentifier, scale: Int
    }
    private var cache: [Key: NSCursor] = [:]
    private var fingerprints: [Key: CursorFingerprint] = [:]
    private var order: [Key] = []
    private struct NativeFrame {
        let index: Int
        let resource: GLCursorResource
        let slot: Int
        let bytes: Int
        let fingerprints: [CursorFingerprint]
        var identifier: String { "io.github.rp0902.gallery.frame.\(slot)" }
    }
    private struct NativeLoop {
        let key: Key
        let offset: Int
        let resource: GLCursorResource
        let images: CursorAnimationImages
        let bytes: Int
    }
    private struct NormalKey: Hashable {
        let data: [Data], width: Double, height: Double, hotX: Double, hotY: Double, count: Int, duration: Double
    }
    private var nativeNormals: [String: GLCursorResource] = [:]
    private var nativeAliases: [String: [String]] = [:]
    private var nativeIDGroups: [String: [String]] = [:]
    private var nativeFrames: [Key: NativeFrame] = [:]
    private var nativeFrameOrder: [Key] = []
    private var nextFrameSlot = 0
    private var freeFrameSlots: [Int] = []
    private var nativeFrameBytes = 0
    private var nativeLoops: [String: NativeLoop] = [:]
    private var loopOrder: [String] = []
    private var failedLoops: Set<Key> = []
    private var activeLoop: (key: Key, started: Double)?
    private(set) var nativeAnimationImages: CursorAnimationImages?
    private var recoveryCache: (role: String, scale: Int, frames: [CursorRecoveryImages.Frame])?
    private struct ReleaseClock {
        let role: String, scale: Int, started: Double, duration: Double, count: Int
        var offset = 0.0, index = 0
    }
    private var releaseClock: ReleaseClock?
    private var guardedIDs: [String] = []
    private var guardedKey: Key?
    private(set) var nativeGuardFingerprints: [CursorFingerprint] = []
    private var submittedSeeds: [Int32: Key] = [:]
    private var seedOrder: [Int32] = []
    private var lastKey: Key?
    private var backgroundOwned = false
    private var shellOverride = false
    private var smoothEdges = true
    private var submissionRevision = 0
    var imageRevision: Int { submissionRevision }
    private var nativeSyncPending = false
    var needsConfirmation: Bool { pendingImage != nil || nativeSyncPending }
    private(set) var pendingImage: (revision: Int, fingerprint: CursorFingerprint)?
    private(set) var nextFrameDeadline: Double?
    private(set) var displayedFrame: Data?
    private(set) var size = CGSize.zero
    private(set) var submissions = 0
    #if GALLERY_RUNTIME_CHECKS
    var testDelayedSeed = false
    private(set) var frameRecords: [[String: Any]] = []
    #endif
    // Another app can reselect an older frame of this very same role. Only the
    // current image, motion and scale count as current ownership.
    func owns(seed: Int32) -> Bool { seed >= 0 && lastKey != nil && submittedSeeds[seed] == lastKey }
    func knownRole(seed: Int32) -> String? { submittedSeeds[seed]?.role }
    var nativeRecoveryImages: CursorRecoveryImages? {
        guard nativeAnimationImages == nil, let key = guardedKey else { return nil }
        if recoveryCache?.role != key.role || recoveryCache?.scale != key.scale {
            recoveryCache = (key.role, key.scale, nativeFrames.filter { $0.key.role == key.role && $0.key.scale == key.scale }
                .map { CursorRecoveryImages.Frame(releaseIndex: $0.key.motion == .release ? $0.value.index : nil, images: $0.value.fingerprints) })
        }
        return CursorRecoveryImages(role: key.role, releasing: key.motion == .release, frames: recoveryCache?.frames ?? [])
    }
    func adoptReleaseFrame(_ index: Int, role: String, started: Double, now: Double, clip: CursorClip) {
        let scale = releaseClock?.scale ?? lastKey?.scale ?? 10000
        if releaseClock?.role != role || releaseClock?.started != started {
            releaseClock = ReleaseClock(role: role, scale: scale, started: started, duration: clip.frameDuration, count: clip.frames.count)
        }
        guard var clock = releaseClock else { return }
        clock.index = max(clock.index, min(clock.count - 1, max(0, index)))
        clock.offset = max(clock.offset, Double(clock.index) * clock.duration - max(0, now - started))
        releaseClock = clock
    }
    private func remember(seed: Int32, key: Key) {
        guard seed >= 0 else { return }
        if submittedSeeds[seed] == nil { seedOrder.append(seed) }
        submittedSeeds[seed] = key
        if seedOrder.count > 256 { submittedSeeds.removeValue(forKey: seedOrder.removeFirst()) }
    }
    func confirmPending(seed: Int32, revision: Int) -> Bool {
        guard pendingImage?.revision == revision, let key = lastKey else { return false }
        remember(seed: seed, key: key); pendingImage = nil
        return true
    }
    func confirmDisplayed(seed: Int32, revision: Int) -> Bool {
        guard submissionRevision == revision, let key = lastKey else { return false }
        remember(seed: seed, key: key); pendingImage = nil; nativeSyncPending = false; return true
    }
    func configureNativeNormals(_ dictionaries: [String: [String: Any]], visualClips: [String: CursorClip] = [:], smoothEdges: Bool = true) {
        self.smoothEdges = smoothEdges
        restoreNativeNormals(); nativeNormals.removeAll(); nativeAliases.removeAll(); nativeIDGroups.removeAll()
        var prepared: [NormalKey: GLCursorResource] = [:]
        var equivalent: [NormalKey: [String]] = [:]
        for (id, dictionary) in dictionaries {
            guard let data = dictionary["Representations"] as? [Data] else { continue }
            func number(_ key: String) -> Double { (dictionary[key] as? NSNumber)?.doubleValue ?? 0 }
            let key = NormalKey(data: data, width: number("PointsWide"), height: number("PointsHigh"),
                hotX: number("HotSpotX"), hotY: number("HotSpotY"), count: Int(number("FrameCount")), duration: number("FrameDuration"))
            if prepared[key] == nil { prepared[key] = GLCursorBridge.prepareCursor(dictionary) }
            nativeNormals[id] = prepared[key]
            // Finder may reselect a drag-copy entry while the matcher keeps
            // the visually identical arrow role. Keep those entry points on
            // the same interaction frame without merging their editable settings.
            // Static images have no meaningful playback duration.
            if nativeNormals[id] != nil {
                let source = visualClips[id]
                let count = source?.frames.count ?? key.count
                let visualKey = NormalKey(data: source?.frames ?? key.data, width: source?.width ?? key.width, height: source?.height ?? key.height,
                    hotX: source?.hotX ?? key.hotX, hotY: source?.hotY ?? key.hotY, count: count,
                    duration: count == 1 ? 0 : source?.frameDuration ?? key.duration)
                equivalent[visualKey, default: []].append(id)
            }
        }
        for ids in equivalent.values { for id in ids { nativeAliases[id] = ids } }
        nativeIDGroups = Dictionary(grouping: nativeNormals.keys, by: CursorCatalog.family).mapValues {
            Set($0.flatMap { nativeAliases[$0] ?? [$0] }).sorted()
        }
    }
    private func nativeFrame(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip) -> NativeFrame? {
        if let frame = nativeFrames[key] {
            nativeFrameOrder.removeAll { $0 == key }; nativeFrameOrder.append(key)
            return frame
        }
        // A two-frame resource with identical images stays on WindowServer's
        // animation path. Static replacement intermittently changes the visible
        // scale even when every submitted bitmap has identical dimensions.
        let source = prepared.frames[index].image
        guard let representations = nativeRasters([source, source], geometry: geometry),
              let resource = nativeResource(representations, count: 2, geometry: geometry) else { return nil }
        let bytes = rasterBytes(representations)
        while nativeFrames.count >= 192 || (nativeFrameBytes + bytes > 32 * 1024 * 1024 && !nativeFrames.isEmpty) {
            guard let oldest = nativeFrameOrder.first(where: { $0 != guardedKey }),
                  let frame = nativeFrames.removeValue(forKey: oldest) else { break }
            nativeFrameOrder.removeAll { $0 == oldest }; nativeFrameBytes -= frame.bytes
            clearSlots([frame.identifier]); freeFrameSlots.append(frame.slot)
        }
        let slot: Int
        if let reused = freeFrameSlots.popLast() { slot = reused }
        else { slot = nextFrameSlot; nextFrameSlot += 1 }
        let identifier = "io.github.rp0902.gallery.frame.\(slot)"
        guard GLCursorBridge.storePreparedCursor(resource, identifiers: [identifier], globally: false) == 0 else {
            freeFrameSlots.append(slot); return nil
        }
        var fingerprints = representations.compactMap {
            CursorFingerprint(image: $0, width: geometry.width, height: geometry.height * 2, hotX: geometry.hotX, hotY: geometry.hotY)
        }
        // Foreground applications can also retain the original single bitmap.
        if let source = CursorFingerprint(image: prepared.frames[index].image, width: geometry.width, height: geometry.height,
            hotX: geometry.hotX, hotY: geometry.hotY) { fingerprints.append(source) }
        let frame = NativeFrame(index: index, resource: resource, slot: slot, bytes: bytes, fingerprints: fingerprints)
        nativeFrames[key] = frame; nativeFrameOrder.append(key); nativeFrameBytes += bytes
        recoveryCache = nil
        return frame
    }
    private func nativeRasters(_ images: [CGImage], geometry: CursorClip) -> [CGImage]? {
        let backingScale = NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 2
        return try? CursorImages.rasters(images, width: geometry.width, height: geometry.height,
            smoothEdges: smoothEdges, maximumScale: min(3, max(1, Int(ceil(backingScale)))))
    }
    private func nativeResource(_ images: [CGImage], count: Int, geometry: CursorClip) -> GLCursorResource? {
        GLCursorBridge.prepareImages(images, frameCount: UInt(count), frameDuration: geometry.frameDuration,
            size: CGSize(width: geometry.width, height: geometry.height), hotSpot: CGPoint(x: geometry.hotX, y: geometry.hotY))
    }
    private func rasterBytes(_ images: [CGImage]) -> Int { images.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    private func guardedIdentifiers(for role: String) -> [String] { nativeIDGroups[CursorCatalog.family(role)] ?? [] }
    func warmInteraction(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double, limit: Int = 24) {
        if motion == .normal && (2...24).contains(prepared.frames.count) && !CursorCatalog.isResize(role) { return }
        let quantizedScale = Int((scale * 10000).rounded())
        let geometry = prepared.clip.scaled(by: Double(quantizedScale) / 10000).alignedToPixels()
        var warmed = Set<ObjectIdentifier>()
        for index in prepared.frames.indices {
            guard warmed.count < limit else { break }
            guard warmed.insert(ObjectIdentifier(prepared.frames[index].image)).inserted else { continue }
            let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), scale: quantizedScale)
            _ = nativeFrame(prepared, index: index, key: key, geometry: geometry)
        }
    }
    private func restoreNativeNormals() {
        let groups = Dictionary(grouping: guardedIDs.filter { nativeNormals[$0] != nil }, by: { ObjectIdentifier(nativeNormals[$0]!) })
        for ids in groups.values {
            _ = GLCursorBridge.storePreparedCursor(nativeNormals[ids[0]]!, identifiers: ids, globally: true)
        }
        guardedIDs.removeAll(); guardedKey = nil; nativeGuardFingerprints.removeAll()
        nativeAnimationImages = nil; activeLoop = nil; nativeSyncPending = false
    }
    private func synchronizeNative(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip, enabled: Bool,
                                   started: Double, now: Double) -> Bool {
        let synchronized = key.motion != .normal || (prepared.frames.count > 1 && !CursorCatalog.isResize(key.role))
        guard enabled, synchronized else { if !guardedIDs.isEmpty { restoreNativeNormals() }; return false }
        guard GLCursorBridge.cursorVisibility() != 0 else { return false }
        let ids = guardedIdentifiers(for: key.role)
        guard !ids.isEmpty else { return false }
        if guardedIDs != ids { restoreNativeNormals() }
        if guardedKey == key && activeLoop == nil && (owns(seed: GLCursorBridge.cursorSeed()) || nativeSyncPending) { return true }
        guard let frame = nativeFrame(prepared, index: index, key: key, geometry: geometry) else { return false }
        if !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return false }
            backgroundOwned = true
        }
        // Update aliases silently, then select an immutable, connection-local
        // slot. Never replace the resource currently being scanned out.
        guardedIDs = ids
        #if GALLERY_RUNTIME_CHECKS
        let begin = ProcessInfo.processInfo.systemUptime
        #endif
        guard GLCursorBridge.storePreparedCursor(frame.resource, identifiers: ids, globally: true) == 0,
              GLCursorBridge.selectCursorIdentifier(frame.identifier) == 0 else { restoreNativeNormals(); return false }
        activeLoop = nil; nativeAnimationImages = nil
        guardedKey = key; nativeGuardFingerprints = frame.fingerprints
        nativeSyncPending = true
        submissionRevision += 1; pendingImage = nil; lastKey = key; submissions += 1
        #if GALLERY_RUNTIME_CHECKS
        let completed = ProcessInfo.processInfo.systemUptime
        frameRecords.append(["role": key.role, "motion": key.motion.rawValue, "index": index, "started": started, "at": now,
            "nativePaired": true, "completedAt": completed, "submitMs": (completed - begin) * 1000,
            "width": size.width, "height": size.height])
        if frameRecords.count > 500 { frameRecords.removeFirst() }
        #endif
        return true
    }
    private func presentLoop(_ prepared: PreparedClip, role: String, scale: Int, started: Double, now: Double) -> Bool {
        let key = Key(role: role, motion: .normal, image: ObjectIdentifier(prepared.frames[0].image), scale: scale)
        guard !failedLoops.contains(key) else { return false }
        let geometry = prepared.clip.scaled(by: Double(scale) / 10000).alignedToPixels()
        let index = max(0, Int((now - started) / geometry.frameDuration)) % prepared.frames.count
        size = CGSize(width: geometry.width, height: geometry.height); displayedFrame = prepared.frames[index].data
        if activeLoop?.key == key, activeLoop?.started == started,
           owns(seed: GLCursorBridge.cursorSeed()) || nativeSyncPending { nextFrameDeadline = nil; return true }
        guard GLCursorBridge.cursorVisibility() != 0 else { return false }
        let ids = guardedIdentifiers(for: role)
        guard !ids.isEmpty else { return false }
        let identifier = "io.github.rp0902.gallery.loop." + role
        if nativeLoops[role]?.key != key || nativeLoops[role]?.offset != index {
            let rotated = Array(prepared.frames[index...]) + Array(prepared.frames[..<index])
            guard let rasters = nativeRasters(rotated.map(\.image), geometry: geometry),
                  let resource = nativeResource(rasters, count: rotated.count, geometry: geometry),
                  let images = CursorAnimationImages(images: rasters, count: rotated.count,
                    size: CGSize(width: geometry.width, height: geometry.height), hotSpot: CGPoint(x: geometry.hotX, y: geometry.hotY)) else { failedLoops.insert(key); return false }
            // The selected loop is immutable. Prepare a replacement only when
            // re-entering a role or changing its scale, retaining playback phase.
            if activeLoop?.key.role == role { restoreNativeNormals() }
            guard GLCursorBridge.storePreparedCursor(resource, identifiers: [identifier], globally: false) == 0 else {
                failedLoops.insert(key); return false
            }
            let bytes = rasterBytes(rasters)
            nativeLoops[role] = NativeLoop(key: key, offset: index, resource: resource, images: images, bytes: bytes)
        }
        guard let loop = nativeLoops[role] else { return false }
        loopOrder.removeAll { $0 == role }; loopOrder.append(role)
        // Retain one phase per role and cap decoded loop storage. Replacing an
        // evicted local slot releases its WindowServer allocation as well.
        while nativeLoops.count > 8 || (nativeLoops.values.reduce(0) { $0 + $1.bytes } > 48 * 1024 * 1024 && nativeLoops.count > 1) {
            guard let oldest = loopOrder.first(where: { $0 != role && $0 != activeLoop?.key.role }) else { break }
            nativeLoops.removeValue(forKey: oldest); loopOrder.removeAll { $0 == oldest }
            clearSlots(["io.github.rp0902.gallery.loop." + oldest])
        }
        if guardedIDs != ids { restoreNativeNormals() }
        if !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return false }; backgroundOwned = true
        }
        guardedIDs = ids
        guard GLCursorBridge.storePreparedCursor(loop.resource, identifiers: ids, globally: true) == 0,
              GLCursorBridge.selectCursorIdentifier(identifier) == 0 else {
            failedLoops.insert(key); restoreNativeNormals(); return false
        }
        activeLoop = (key, started); guardedKey = key; lastKey = key
        nativeAnimationImages = loop.images; nativeGuardFingerprints = []
        pendingImage = nil; nativeSyncPending = true; nextFrameDeadline = nil
        submissionRevision += 1; submissions += 1
        #if GALLERY_RUNTIME_CHECKS
        frameRecords.append(["role": role, "motion": "normal", "index": index, "started": started, "at": now,
            "nativeLoop": true, "count": prepared.frames.count, "width": size.width, "height": size.height])
        if frameRecords.count > 500 { frameRecords.removeFirst() }
        #endif
        return true
    }
    private lazy var emptySlot: GLCursorResource? = {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        return GLCursorBridge.prepareImages([image], frameCount: 1, frameDuration: 0.05, size: CGSize(width: 1, height: 1), hotSpot: .zero)
    }()
    private func clearSlots(_ identifiers: [String]) {
        guard !identifiers.isEmpty, let emptySlot else { return }
        _ = GLCursorBridge.storePreparedCursor(emptySlot, identifiers: identifiers, globally: false)
    }
    func cancelPending() { pendingImage = nil; nativeSyncPending = false }
    func present(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double,
                 started: Double, now: Double, staticOnly: Bool = false, synchronizeRegistration: Bool = false, shell: Bool = false) {
        if shellOverride != shell { GLCursorBridge.setDockCursorOverride(shell); shellOverride = shell }
        let clip = prepared.clip
        let scaleKey = Int((scale * 10000).rounded())
        if motion == .normal && !staticOnly && synchronizeRegistration && (2...24).contains(prepared.frames.count)
            && !CursorCatalog.isResize(role), presentLoop(prepared, role: role, scale: scaleKey, started: started, now: now) { return }
        var displayStart = started
        if motion == .release && !staticOnly {
            if releaseClock?.role != role || releaseClock?.started != started || releaseClock?.scale != scaleKey {
                releaseClock = ReleaseClock(role: role, scale: scaleKey, started: started, duration: clip.frameDuration, count: clip.frames.count)
            }
            if let visible = submittedSeeds[GLCursorBridge.cursorSeed()], visible.role == role, visible.motion == .release,
               let index = prepared.frames.firstIndex(where: { ObjectIdentifier($0.image) == visible.image }) {
                adoptReleaseFrame(index, role: role, started: started, now: now, clip: clip)
            }
            displayStart -= releaseClock?.offset ?? 0
        } else { releaseClock = nil }
        let step = max(motion == .release ? (releaseClock?.index ?? 0) : 0, max(0, Int((now - displayStart) / clip.frameDuration)))
        let index = staticOnly ? 0 : (motion.loops ? step % prepared.frames.count : min(step, prepared.frames.count - 1))
        if motion == .release {
            let advanced = max(releaseClock?.index ?? 0, index)
            releaseClock?.index = advanced
        }
        nextFrameDeadline = staticOnly ? nil : prepared.schedule.nextChange(after: step, looping: motion.loops).map {
            let cadence = displayStart + (floor(max(0, now - displayStart) * 60) + 1) / 60
            return max(now + 0.001, max(cadence, displayStart + Double($0) * clip.frameDuration))
        }
        let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), scale: scaleKey)
        let geometry = clip.scaled(by: Double(key.scale) / 10000).alignedToPixels()
        size = CGSize(width: geometry.width, height: geometry.height); displayedFrame = prepared.frames[index].data
        if synchronizeNative(prepared, index: index, key: key, geometry: geometry, enabled: synchronizeRegistration && !staticOnly,
                             started: started, now: now) { return }
        let seed = GLCursorBridge.cursorSeed()
        if lastKey == key && (owns(seed: seed) || pendingImage != nil) { return }
        // Respect cursor hiding owned by the foreground app (typing, games).
        // There are no Gallery hide tickets to accumulate or recover here.
        guard GLCursorBridge.cursorVisibility() != 0 else { return }
        let cursor: NSCursor
        if let existing = cache[key] { cursor = existing }
        else {
            cursor = NSCursor(image: cursorImage(prepared.frames[index].image, size: size),
                              hotSpot: NSPoint(x: geometry.hotX, y: geometry.hotY))
            cache[key] = cursor; order.append(key)
            if order.count > 256 { let oldest = order.removeFirst(); cache.removeValue(forKey: oldest); fingerprints.removeValue(forKey: oldest) }
        }
        if !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return }
            backgroundOwned = true
        }
        let before = GLCursorBridge.cursorSeed()
        let actual = GLCursorBridge.present(cursor)
        #if GALLERY_RUNTIME_CHECKS
        let returned = testDelayedSeed ? before : actual
        #else
        let returned = actual
        #endif
        submissionRevision += 1; pendingImage = nil
        if returned >= 0 && returned != before { remember(seed: returned, key: key) }
        else {
            if fingerprints[key] == nil {
                if let rep = cursor.image.representations.first as? NSBitmapImageRep, let raster = rep.cgImage {
                    fingerprints[key] = CursorFingerprint(image: raster,
                        width: geometry.width, height: geometry.height, hotX: geometry.hotX, hotY: geometry.hotY)
                }
            }
            if let fingerprint = fingerprints[key] { pendingImage = (submissionRevision, fingerprint) }
        }
        lastKey = key; submissions += 1
        #if GALLERY_RUNTIME_CHECKS
        frameRecords.append(["role": role, "motion": motion.rawValue, "index": index, "started": started, "at": now,
            "completedAt": ProcessInfo.processInfo.systemUptime, "before": before, "returned": returned, "width": size.width, "height": size.height])
        if frameRecords.count > 500 { frameRecords.removeFirst() }
        #endif
    }
    private func cursorImage(_ source: CGImage, size: CGSize) -> NSImage {
        // Image interpolation is a one-time cache cost, not a per-frame filter.
        // Explicit representations also make the sharp/pixel-art option work
        // in the fallback path and during temporary shake enlargement.
        let image = NSImage(size: size)
        if let rasters = try? CursorImages.rasters([source], width: size.width, height: size.height, smoothEdges: smoothEdges) {
            for raster in rasters {
                let rep = NSBitmapImageRep(cgImage: raster); rep.size = size; image.addRepresentation(rep)
            }
        }
        return image.representations.isEmpty ? NSImage(cgImage: source, size: size) : image
    }
    func passThrough(frame: Data? = nil, size: CGSize = .zero) {
        if shellOverride { GLCursorBridge.setDockCursorOverride(false); shellOverride = false }
        restoreNativeNormals()
        if backgroundOwned { _ = GLCursorBridge.setBackgroundCursorUpdates(false); backgroundOwned = false }
        lastKey = nil; pendingImage = nil; nextFrameDeadline = nil; displayedFrame = frame; self.size = size
        releaseClock = nil
    }
    func stop(restoring original: [String: Any]?) {
        if backgroundOwned, let original, let clip = try? CursorImages.fromCape(original),
           let data = clip.frames.first, let image = try? CursorImages.bitmap(data) {
            let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: clip.width, height: clip.height)),
                                  hotSpot: NSPoint(x: clip.hotX, y: clip.hotY))
            _ = GLCursorBridge.present(cursor)
        }
        passThrough(); cache.removeAll(); fingerprints.removeAll(); order.removeAll(); submittedSeeds.removeAll(); seedOrder.removeAll()
        clearSlots((0..<nextFrameSlot).map { "io.github.rp0902.gallery.frame.\($0)" }
            + nativeLoops.keys.map { "io.github.rp0902.gallery.loop." + $0 })
        nativeFrames.removeAll(); nativeFrameOrder.removeAll(); nativeNormals.removeAll(); nativeAliases.removeAll(); nativeIDGroups.removeAll()
        nativeFrameBytes = 0; nextFrameSlot = 0; freeFrameSlots.removeAll()
        nativeLoops.removeAll(); loopOrder.removeAll(); failedLoops.removeAll(); recoveryCache = nil
    }
}
