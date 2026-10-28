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
    private var submittedSeeds: [Int32: String] = [:]
    private var seedOrder: [Int32] = []
    private var lastKey: Key?
    private var backgroundOwned = false
    private var submissionRevision = 0
    private(set) var pendingImage: (revision: Int, fingerprint: CursorFingerprint)?
    private(set) var nextFrameDeadline: Double?
    private(set) var displayedFrame: Data?
    private(set) var size = CGSize.zero
    private(set) var submissions = 0
    #if GALLERY_RUNTIME_CHECKS
    var testDelayedSeed = false
    #endif
    // The same cached resource seed can reappear when another application
    // selects a previously used role. A history hit alone is not ownership.
    func owns(seed: Int32) -> Bool { seed >= 0 && lastKey != nil && submittedSeeds[seed] == lastKey?.role }
    private func remember(seed: Int32, role: String) {
        guard seed >= 0 else { return }
        if submittedSeeds[seed] == nil { seedOrder.append(seed) }
        submittedSeeds[seed] = role
        if seedOrder.count > 256 { submittedSeeds.removeValue(forKey: seedOrder.removeFirst()) }
    }
    func confirmPending(seed: Int32, revision: Int) -> Bool {
        guard pendingImage?.revision == revision, let role = lastKey?.role else { return false }
        remember(seed: seed, role: role); pendingImage = nil
        return true
    }
    func cancelPending() { pendingImage = nil }
    func present(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double,
                 started: Double, now: Double, staticOnly: Bool = false) {
        let clip = prepared.clip
        let step = max(0, Int((now - started) / clip.frameDuration))
        let index = staticOnly ? 0 : (motion.loops ? step % prepared.frames.count : min(step, prepared.frames.count - 1))
        nextFrameDeadline = staticOnly ? nil : prepared.schedule.nextChange(after: step, looping: motion.loops).map {
            now + max(1.0 / 60, started + Double($0) * clip.frameDuration - now)
        }
        let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), scale: Int((scale * 100).rounded()))
        let geometry = clip.scaled(by: Double(key.scale) / 100)
        size = CGSize(width: geometry.width, height: geometry.height); displayedFrame = prepared.frames[index].data
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
        if returned >= 0 && returned != before { remember(seed: returned, role: role) }
        else {
            // An unchanged return value is still the preceding foreground
            // resource. A matching capture must acknowledge the delayed seed.
            if fingerprints[key] == nil {
                fingerprints[key] = CursorFingerprint(image: prepared.frames[index].image,
                    width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY)
            }
            if let fingerprint = fingerprints[key] { pendingImage = (submissionRevision, fingerprint) }
        }
        lastKey = key; submissions += 1
    }
    func passThrough(frame: Data? = nil, size: CGSize = .zero) {
        if backgroundOwned { _ = GLCursorBridge.setBackgroundCursorUpdates(false); backgroundOwned = false }
        lastKey = nil; pendingImage = nil; nextFrameDeadline = nil; displayedFrame = frame; self.size = size
    }
    func stop(restoring original: [String: Any]?) {
        if backgroundOwned, let original, let clip = try? CursorImages.fromCape(original),
           let data = clip.frames.first, let image = try? CursorImages.bitmap(data) {
            let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: clip.width, height: clip.height)),
                                  hotSpot: NSPoint(x: clip.hotX, y: clip.hotY))
            _ = GLCursorBridge.present(cursor)
        }
        passThrough(); cache.removeAll(); fingerprints.removeAll(); order.removeAll(); submittedSeeds.removeAll(); seedOrder.removeAll()
    }
}
