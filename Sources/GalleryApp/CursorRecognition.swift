import Foundation
import GalleryCore
import GalleryNative

/// One worker, one in-flight request. Cached immutable WindowServer seeds
/// avoid image capture and matching when the cursor resource hasn't changed.
final class CursorRecognition: @unchecked Sendable {
    private let matcher: CursorMatcher
    private let queue = DispatchQueue(label: "Gallery.cursor-recognition", qos: .userInitiated)
    private var cache: [Int32: CursorIdentification] = [:]
    private var cachedAt: [Int32: Double] = [:]
    private var order: [Int32] = []
    private var captureMisses: [Int32: (Double, Int)] = [:]
    init(matcher: CursorMatcher) { self.matcher = matcher }
    func probe(_ completion: @escaping @Sendable (Int32, CursorIdentification?) -> Void) {
        queue.async { [self] in
            autoreleasepool {
                let seed = GLCursorBridge.cursorSeed()
                let now = ProcessInfo.processInfo.systemUptime
                if seed >= 0, let found = cache[seed], !found.roles.isEmpty || now - (cachedAt[seed] ?? 0) < 0.5 {
                    completion(seed, found); return
                }
                guard let snapshot = GLCursorBridge.currentSnapshot() else {
                    if seed >= 0, seed == GLCursorBridge.cursorSeed() {
                        let previous = captureMisses[seed] ?? (now, 0)
                        captureMisses[seed] = (previous.0, previous.1 + 1)
                        if previous.1 > 0 && now - previous.0 >= 0.04 {
                            remember(.unknown, seed: seed, now: now); completion(seed, .unknown)
                        } else { completion(seed, nil) }
                        if captureMisses.count > 64 { captureMisses.removeAll(keepingCapacity: true) }
                    } else { completion(seed, nil) }
                    return
                }
                captureMisses.removeValue(forKey: snapshot.seed)
                let found = matcher.identify(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
                    hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y)
                if snapshot.seed >= 0 {
                    remember(found, seed: snapshot.seed, now: now)
                }
                completion(snapshot.seed, found)
            }
        }
    }
    private func remember(_ found: CursorIdentification, seed: Int32, now: Double) {
        if cache[seed] == nil { order.append(seed) }
        cache[seed] = found; cachedAt[seed] = now
        if order.count > 256 { let oldest = order.removeFirst(); cache.removeValue(forKey: oldest); cachedAt.removeValue(forKey: oldest) }
    }
}
