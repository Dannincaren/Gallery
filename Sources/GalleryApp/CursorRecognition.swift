import Foundation
import GalleryCore
import GalleryNative

struct CursorRecoveryImages: Sendable {
    struct Frame: Sendable { let releaseIndex: Int?; let images: [CursorFingerprint] }
    let role: String
    var releasing: Bool
    let frames: [Frame]
}

/// One worker, one in-flight request. Cached immutable WindowServer seeds
/// avoid image capture and matching when the cursor resource hasn't changed.
final class CursorRecognition: @unchecked Sendable {
    private let matcher: CursorMatcher
    private let queue = DispatchQueue(label: "Gallery.cursor-recognition", qos: .userInitiated)
    private var cache: [Int32: CursorIdentification] = [:]
    private var cachedAt: [Int32: Double] = [:]
    private var order: [Int32] = []
    private var captureMisses: [Int32: (Double, Int)] = [:]
    #if GALLERY_RUNTIME_CHECKS
    private var debuggedSeed: Int32 = -1
    #endif
    init(matcher: CursorMatcher) { self.matcher = matcher }
    func probe(pendingImage: CursorFingerprint? = nil, nativeImages: [CursorFingerprint] = [],
               nativeRecovery: CursorRecoveryImages? = nil,
               _ completion: @escaping @Sendable (Int32, CursorIdentification?, Bool, Int?) -> Void) {
        queue.async { [self] in
            autoreleasepool {
                let seed = GLCursorBridge.cursorSeed()
                let now = ProcessInfo.processInfo.systemUptime
                if pendingImage == nil, nativeImages.isEmpty, nativeRecovery == nil, seed >= 0, let found = cache[seed], !found.roles.isEmpty || now - (cachedAt[seed] ?? 0) < 0.5 {
                    completion(seed, found, false, nil); return
                }
                guard let snapshot = GLCursorBridge.currentSnapshot() else {
                    if seed >= 0, seed == GLCursorBridge.cursorSeed() {
                        let previous = captureMisses[seed] ?? (now, 0)
                        captureMisses[seed] = (previous.0, previous.1 + 1)
                        if previous.1 > 0 && now - previous.0 >= 0.04 {
                            remember(.unknown, seed: seed, now: now); completion(seed, .unknown, false, nil)
                        } else { completion(seed, nil, false, nil) }
                        if captureMisses.count > 64 { captureMisses.removeAll(keepingCapacity: true) }
                    } else { completion(seed, nil, false, nil) }
                    return
                }
                captureMisses.removeValue(forKey: snapshot.seed)
                if !nativeImages.isEmpty || nativeRecovery != nil,
                   let actual = CursorFingerprint(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
                    hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y) {
                    if nativeImages.contains(where: { actual.distance(to: $0) <= 0.012 }) {
                        completion(snapshot.seed, nil, true, nil); return
                    }
                    if let recovery = nativeRecovery {
                        let matches = recovery.frames.filter { $0.images.contains { actual.distance(to: $0) <= 0.012 } }
                        if !matches.isEmpty {
                        // An old interaction image is a known role, but never
                        // acknowledgment of the current frame. Force recovery.
                            let index = recovery.releasing ? matches.compactMap(\.releaseIndex).min() : nil
                            completion(snapshot.seed, CursorIdentification(roles: [recovery.role]), false, index); return
                        }
                    }
                }
                if let pendingImage, let actual = CursorFingerprint(image: snapshot.image,
                    width: snapshot.size.width, height: snapshot.size.height, hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y) {
                    if actual.distance(to: pendingImage) <= 0.012 { completion(snapshot.seed, nil, true, nil); return }
                    #if GALLERY_RUNTIME_CHECKS
                    if ProcessInfo.processInfo.environment["GALLERY_ACK_DEBUG"] == "1", debuggedSeed != snapshot.seed {
                        debuggedSeed = snapshot.seed
                        print("PENDING MISMATCH", snapshot.seed, actual.geometryDescription, pendingImage.geometryDescription, actual.visualDistance(to: pendingImage))
                    }
                    #endif
                }
                let found = matcher.identify(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
                    hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y)
                if snapshot.seed >= 0 {
                    remember(found, seed: snapshot.seed, now: now)
                }
                completion(snapshot.seed, found, false, nil)
            }
        }
    }
    private func remember(_ found: CursorIdentification, seed: Int32, now: Double) {
        if cache[seed] == nil { order.append(seed) }
        cache[seed] = found; cachedAt[seed] = now
        if order.count > 256 { let oldest = order.removeFirst(); cache.removeValue(forKey: oldest); cachedAt.removeValue(forKey: oldest) }
    }
}
