import Foundation
import CoreGraphics
import GalleryCore
import GalleryNative

struct CursorAnimationImages: Sendable {
    struct Sample: Sendable { let index: Int; let images: [CursorFingerprint] }
    let count: Int
    let samples: [Sample]
    init?(dictionary: [String: Any]) {
        guard let count = (dictionary["FrameCount"] as? NSNumber)?.intValue, count > 1,
              let data = dictionary["Representations"] as? [Data],
              let width = (dictionary["PointsWide"] as? NSNumber)?.doubleValue,
              let height = (dictionary["PointsHigh"] as? NSNumber)?.doubleValue else { return nil }
        let hotX = (dictionary["HotSpotX"] as? NSNumber)?.doubleValue ?? 0
        let hotY = (dictionary["HotSpotY"] as? NSNumber)?.doubleValue ?? 0
        let images = data.compactMap { try? CursorImages.bitmap($0) }
        self.init(images: images, count: count, size: CGSize(width: width, height: height), hotSpot: CGPoint(x: hotX, y: hotY))
    }
    init?(images: [CGImage], count: Int, size: CGSize, hotSpot: CGPoint) {
        guard count > 1 else { return nil }
        let samples = Set([0, count / 2, count - 1]).sorted().map { index in
            Sample(index: index, images: images.compactMap { image in
                guard image.height % count == 0,
                      let frame = image.cropping(to: CGRect(x: 0, y: index * (image.height / count), width: image.width, height: image.height / count)) else { return nil }
                return CursorFingerprint(image: frame, width: size.width, height: size.height, hotX: hotSpot.x, hotY: hotSpot.y)
            })
        }
        guard samples.allSatisfy({ !$0.images.isEmpty }) else { return nil }
        self.count = count; self.samples = samples
    }
    func matches(image: CGImage, size: CGSize, hotSpot: CGPoint) -> Bool {
        guard count > 1, image.height % count == 0 else { return false }
        let height = image.height / count, pointsHigh = size.height / Double(count)
        guard height > 0, pointsHigh > hotSpot.y else { return false }
        return samples.allSatisfy { sample in
            guard let frame = image.cropping(to: CGRect(x: 0, y: sample.index * height, width: image.width, height: height)),
                  let actual = CursorFingerprint(image: frame, width: size.width, height: pointsHigh, hotX: hotSpot.x, hotY: hotSpot.y) else { return false }
            return sample.images.contains { actual.matches($0) }
        }
    }
}

struct CursorRecoveryImages: Sendable {
    struct Frame: Sendable { let releaseIndex: Int?; let images: [CursorFingerprint] }
    let role: String
    var releasing: Bool
    let frames: [Frame]
}

/// One worker, one in-flight request. Cached immutable WindowServer seeds
/// avoid image capture and matching when the cursor resource hasn't changed.
final class CursorRecognition: @unchecked Sendable {
    private let sourceMatcher: CursorMatcher
    private var matcher: CursorMatcher
    private let queue = DispatchQueue(label: "Gallery.cursor-recognition", qos: .userInitiated)
    private var cache: [Int32: CursorIdentification] = [:]
    private var cachedAt: [Int32: Double] = [:]
    private var order: [Int32] = []
    private var captureMisses: [Int32: (Double, Int)] = [:]
    #if GALLERY_RUNTIME_CHECKS
    private var debuggedSeed: Int32 = -1
    #endif
    init(matcher: CursorMatcher, registered: [String: [String: Any]] = [:]) {
        sourceMatcher = matcher
        self.matcher = Self.registeredMatcher(matcher, dictionaries: registered)
    }
    private static func registeredMatcher(_ source: CursorMatcher, dictionaries: [String: [String: Any]]) -> CursorMatcher {
        var matcher = source
        for (id, dictionary) in dictionaries { matcher.addRepresentations(dictionary, role: id, applied: true) }
        return matcher
    }
    func updateRegistered(_ dictionaries: [String: [String: Any]]) {
        queue.async { [self] in
            // Rebuild from the source bank instead of accumulating every
            // historical slider size. Thin text artwork changes substantially
            // when rasterized down to the actual registered 1x/2x images.
            matcher = Self.registeredMatcher(sourceMatcher, dictionaries: dictionaries)
            cache.removeAll(keepingCapacity: true); cachedAt.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true)
        }
    }
    func probe(pendingImage: CursorFingerprint? = nil, nativeImages: [CursorFingerprint] = [], nativeAnimation: CursorAnimationImages? = nil,
               nativeRecovery: CursorRecoveryImages? = nil,
               _ completion: @escaping @Sendable (Int32, CursorIdentification?, Bool, Int?) -> Void) {
        queue.async { [self] in
            autoreleasepool {
                let seed = GLCursorBridge.cursorSeed()
                let now = ProcessInfo.processInfo.systemUptime
                if pendingImage == nil, nativeImages.isEmpty, nativeAnimation == nil, nativeRecovery == nil, seed >= 0, let found = cache[seed], !found.roles.isEmpty || now - (cachedAt[seed] ?? 0) < 0.5 {
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
                if nativeAnimation?.matches(image: snapshot.image, size: snapshot.size, hotSpot: snapshot.hotSpot) == true {
                    completion(snapshot.seed, nil, true, nil); return
                }
                // One immutable snapshot, one fingerprint, shared by the
                // current frame, historical frame and semantic-role checks.
                let actual = CursorFingerprint(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
                    hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y)
                if let actual {
                    if nativeImages.contains(where: { actual.matches($0) }) {
                        completion(snapshot.seed, nil, true, nil); return
                    }
                    if let recovery = nativeRecovery {
                        var matched = false, releaseIndex: Int?
                        for frame in recovery.frames where frame.images.contains(where: { actual.matches($0) }) {
                            matched = true
                            if recovery.releasing, let index = frame.releaseIndex { releaseIndex = min(releaseIndex ?? index, index) }
                        }
                        if matched {
                        // An old interaction image is a known role, but never
                        // acknowledgment of the current frame. Force recovery.
                            completion(snapshot.seed, CursorIdentification(roles: [recovery.role]), false, releaseIndex); return
                        }
                    }
                }
                if let pendingImage, let actual {
                    if actual.matches(pendingImage) { completion(snapshot.seed, nil, true, nil); return }
                    #if GALLERY_RUNTIME_CHECKS
                    if ProcessInfo.processInfo.environment["GALLERY_ACK_DEBUG"] == "1", debuggedSeed != snapshot.seed {
                        debuggedSeed = snapshot.seed
                        print("PENDING MISMATCH", snapshot.seed, actual.geometryDescription, pendingImage.geometryDescription, actual.visualDistance(to: pendingImage))
                    }
                    #endif
                }
                let found = matcher.identify(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
                    hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y, sample: actual)
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
