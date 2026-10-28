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
        let cursor: NSCursor
        let fingerprints: [CursorFingerprint]
    }
    private struct NormalKey: Hashable {
        let data: [Data], width: Double, height: Double, hotX: Double, hotY: Double, count: Int, duration: Double
    }
    private var nativeNormals: [String: GLCursorResource] = [:]
    private var nativeAliases: [String: [String]] = [:]
    private var nativeFrames: [Key: NativeFrame] = [:]
    private var nativeFrameOrder: [Key] = []
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
        guard let key = guardedKey else { return nil }
        if recoveryCache?.role != key.role || recoveryCache?.scale != key.scale {
            recoveryCache = (key.role, key.scale, nativeFrames.filter { $0.key.role == key.role && $0.key.scale == key.scale }
                .map { CursorRecoveryImages.Frame(releaseIndex: $0.key.motion == .release ? $0.value.index : nil, images: $0.value.fingerprints) })
        }
        return CursorRecoveryImages(role: key.role, releasing: key.motion == .release, frames: recoveryCache?.frames ?? [])
    }
    func adoptReleaseFrame(_ index: Int, role: String, started: Double, now: Double, clip: CursorClip) {
        let scale = releaseClock?.scale ?? lastKey?.scale ?? 100
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
    func configureNativeNormals(_ dictionaries: [String: [String: Any]], visualClips: [String: CursorClip] = [:]) {
        restoreNativeNormals(); nativeNormals.removeAll(); nativeAliases.removeAll()
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
    }
    private func nativeFrame(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip) -> NativeFrame? {
        if let frame = nativeFrames[key] { return frame }
        var clip = geometry; clip.frames = [prepared.frames[index].data]
        guard var dictionary = try? CursorImages.capeDictionary(clip),
              let available = dictionary["Representations"] as? [Data] else { return nil }
        let backingScale = NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 2
        let representations = Array(available.prefix(max(1, Int(ceil(backingScale)))))
        dictionary["Representations"] = representations
        guard let resource = GLCursorBridge.prepareCursor(dictionary) else { return nil }
        var fingerprints = representations.compactMap { CursorFingerprint(data: $0, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY) }
        // AppKit can retain the original bitmap while registered entries use
        // resampled 1x/2x/3x images. Recognize both representations precisely.
        if let source = CursorFingerprint(image: prepared.frames[index].image, width: clip.width, height: clip.height,
            hotX: clip.hotX, hotY: clip.hotY) { fingerprints.append(source) }
        let image = NSImage(size: NSSize(width: clip.width, height: clip.height))
        for data in representations {
            if let rep = NSBitmapImageRep(data: data) {
                rep.size = image.size; image.addRepresentation(rep)
            }
        }
        // Use the very same resolution variants as the registered cursor;
        // foreground selection must not switch rasterization mid-animation.
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: clip.hotX, y: clip.hotY))
        let frame = NativeFrame(index: index, resource: resource, cursor: cursor, fingerprints: fingerprints)
        nativeFrames[key] = frame; nativeFrameOrder.append(key)
        if nativeFrameOrder.count > 96 { nativeFrames.removeValue(forKey: nativeFrameOrder.removeFirst()) }
        recoveryCache = nil
        return frame
    }
    func warmInteraction(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double, limit: Int = 24) {
        let quantizedScale = Int((scale * 100).rounded())
        let geometry = prepared.clip.scaled(by: Double(quantizedScale) / 100)
        for index in prepared.frames.indices.prefix(limit) {
            let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), scale: quantizedScale)
            _ = nativeFrame(prepared, index: index, key: key, geometry: geometry)
        }
    }
    private func restoreNativeNormals() {
        let groups = Dictionary(grouping: guardedIDs.filter { nativeNormals[$0] != nil }, by: { ObjectIdentifier(nativeNormals[$0]!) })
        for ids in groups.values { _ = GLCursorBridge.applyPreparedCursor(nativeNormals[ids[0]]!, identifiers: ids) }
        guardedIDs.removeAll(); guardedKey = nil; nativeGuardFingerprints.removeAll()
        nativeSyncPending = false
    }
    private func synchronizeNative(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip, enabled: Bool, started: Double, now: Double) -> Bool {
        // The foreground app may select its drag cursor before our up callback
        // runs. Arm the same static resource while held, so that handoff cannot
        // insert a normal image before release even starts. A static hold adds
        // no frame timer; only its entry or an actual foreground change submits.
        let text = ["com.apple.coregraphics.IBeam", "com.apple.cursor.26"].contains(CursorCatalog.family(key.role))
        let synchronized = key.motion == .hold || key.motion == .release
            || (key.motion == .normal && text && prepared.frames.count > 1)
        guard enabled, synchronized else { if !guardedIDs.isEmpty { restoreNativeNormals() }; return false }
        guard GLCursorBridge.cursorVisibility() != 0 else { return false }
        let familyIDs = nativeNormals.keys.filter { CursorCatalog.family($0) == CursorCatalog.family(key.role) }
        let ids = Set(familyIDs.flatMap { nativeAliases[$0] ?? [$0] }).sorted()
        guard !ids.isEmpty else { return false }
        if guardedIDs != ids { restoreNativeNormals() }
        if guardedKey == key && (owns(seed: GLCursorBridge.cursorSeed()) || nativeSyncPending) { return true }
        guard let frame = nativeFrame(prepared, index: index, key: key, geometry: geometry) else { return false }
        if !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return false }
            backgroundOwned = true
        }
        guardedIDs = ids
        #if GALLERY_RUNTIME_CHECKS
        let begin = ProcessInfo.processInfo.systemUptime
        #endif
        guard GLCursorBridge.applyPreparedCursor(frame.resource, identifiers: ids, showImmediately: true) == 0 else { restoreNativeNormals(); return false }
        _ = GLCursorBridge.present(frame.cursor)
        guardedKey = key; nativeGuardFingerprints = frame.fingerprints
        // Even a changed return seed can belong to an earlier queued update.
        // Only an actual matching image can acknowledge this submission.
        nativeSyncPending = true
        submissionRevision += 1; pendingImage = nil; lastKey = key; submissions += 1
        #if GALLERY_RUNTIME_CHECKS
        let completed = ProcessInfo.processInfo.systemUptime
        frameRecords.append(["role": key.role, "motion": key.motion.rawValue, "index": index, "started": started, "at": now,
            "nativeStatic": true, "paired": true, "completedAt": completed, "submitMs": (completed - begin) * 1000,
            "width": size.width, "height": size.height])
        if frameRecords.count > 500 { frameRecords.removeFirst() }
        #endif
        return true
    }
    func cancelPending() { pendingImage = nil; nativeSyncPending = false }
    func present(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double,
                 started: Double, now: Double, staticOnly: Bool = false, synchronizeRegistration: Bool = false) {
        let clip = prepared.clip
        let scaleKey = Int((scale * 100).rounded())
        var displayStart = started
        if motion == .release && !staticOnly {
            if releaseClock?.role != role || releaseClock?.started != started || releaseClock?.scale != scaleKey {
                releaseClock = ReleaseClock(role: role, scale: scaleKey, started: started, duration: clip.frameDuration, count: clip.frames.count)
            }
            if let visible = submittedSeeds[GLCursorBridge.cursorSeed()], visible.role == role,
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
        let geometry = clip.scaled(by: Double(key.scale) / 100)
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
            cursor = NSCursor(image: NSImage(cgImage: prepared.frames[index].image, size: size),
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
                fingerprints[key] = CursorFingerprint(image: prepared.frames[index].image,
                    width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY)
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
    func passThrough(frame: Data? = nil, size: CGSize = .zero) {
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
        nativeFrames.removeAll(); nativeFrameOrder.removeAll(); nativeNormals.removeAll(); nativeAliases.removeAll()
        recoveryCache = nil
    }
}
