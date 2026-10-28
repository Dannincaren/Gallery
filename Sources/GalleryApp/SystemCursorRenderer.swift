import AppKit
import GalleryCore
import GalleryNative

/// The WindowServer owns cursor position, Spaces and visibility. Gallery only
/// submits cached images. This renderer never hides the cursor or moves a window.
@MainActor
final class SystemCursorRenderer {
    private struct Key: Hashable {
        let role: String, motion: Motion, frame: Int, scale: Int
    }
    private var cache: [Key: NSCursor] = [:]
    private var order: [Key] = []
    private var submittedSeeds: [Int32] = []
    private var lastKey: Key?
    private var backgroundOwned = false
    private(set) var nextFrameDeadline: Double?
    private(set) var displayedFrame: Data?
    private(set) var size = CGSize.zero
    private(set) var submissions = 0
    func owns(seed: Int32) -> Bool { seed >= 0 && submittedSeeds.contains(seed) }
    func present(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double,
                 started: Double, now: Double, staticOnly: Bool = false) {
        let clip = prepared.clip
        let step = max(0, Int((now - started) / clip.frameDuration))
        let index = staticOnly ? 0 : (motion.loops ? step % prepared.frames.count : min(step, prepared.frames.count - 1))
        nextFrameDeadline = !staticOnly && prepared.frames.count > 1 && (motion.loops || index < prepared.frames.count - 1)
            ? now + max(1.0 / 60, started + Double(step + 1) * clip.frameDuration - now) : nil
        let key = Key(role: role, motion: motion, frame: index, scale: Int((scale * 100).rounded()))
        let geometry = clip.scaled(by: Double(key.scale) / 100)
        size = CGSize(width: geometry.width, height: geometry.height); displayedFrame = prepared.frames[index].data
        let seed = GLCursorBridge.cursorSeed()
        if lastKey == key && owns(seed: seed) { return }
        // Respect cursor hiding owned by the foreground app (typing, games).
        // There are no Gallery hide tickets to accumulate or recover here.
        guard GLCursorBridge.cursorVisibility() != 0 else { return }
        let cursor: NSCursor
        if let existing = cache[key] { cursor = existing }
        else {
            cursor = NSCursor(image: NSImage(cgImage: prepared.frames[index].image, size: size),
                              hotSpot: NSPoint(x: geometry.hotX, y: geometry.hotY))
            cache[key] = cursor; order.append(key)
            if order.count > 256 { cache.removeValue(forKey: order.removeFirst()) }
        }
        if !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return }
            backgroundOwned = true
        }
        let submitted = GLCursorBridge.present(cursor)
        if submitted >= 0 {
            submittedSeeds.append(submitted)
            if submittedSeeds.count > 256 { submittedSeeds.removeFirst(submittedSeeds.count - 256) }
        }
        lastKey = key; submissions += 1
    }
    func passThrough(frame: Data? = nil, size: CGSize = .zero) {
        if backgroundOwned { _ = GLCursorBridge.setBackgroundCursorUpdates(false); backgroundOwned = false }
        lastKey = nil; nextFrameDeadline = nil; displayedFrame = frame; self.size = size
    }
    func stop(restoring original: [String: Any]?) {
        if backgroundOwned, let original, let clip = try? CursorImages.fromCape(original),
           let data = clip.frames.first, let image = try? CursorImages.bitmap(data) {
            let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: clip.width, height: clip.height)),
                                  hotSpot: NSPoint(x: clip.hotX, y: clip.hotY))
            _ = GLCursorBridge.present(cursor)
        }
        passThrough(); cache.removeAll(); order.removeAll(); submittedSeeds.removeAll()
    }
}
