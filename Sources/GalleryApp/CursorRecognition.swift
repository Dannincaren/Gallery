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
        // A repeated idle pose can occupy all three former sample positions
        // while the remaining frames belong to a different segment/order.
        // Verify the whole bounded strip before acknowledging its seed. This
        // runs on the recognition worker only when the resource seed changes.
        let samples = (0..<count).map { index in
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
        guard let actual = Self.observation(image: image, size: size, hotSpot: hotSpot, count: count) else { return false }
        return matches(actual)
    }
    static func observation(image: CGImage, size: CGSize, hotSpot: CGPoint, count: Int) -> Self? {
        guard count > 1, image.height % count == 0, size.height / Double(count) > hotSpot.y else { return nil }
        return Self(images: [image], count: count, size: CGSize(width: size.width, height: size.height / Double(count)), hotSpot: hotSpot)
    }
    func matches(_ actual: Self) -> Bool {
        guard count == actual.count else { return false }
        return zip(samples, actual.samples).allSatisfy { expected, sample in
            expected.index == sample.index && sample.images.contains { observed in expected.images.contains { observed.matches($0) } }
        }
    }
}

struct CursorRecoveryImages: Sendable {
    struct Frame: Sendable { let releaseIndex: Int?; let images: [CursorFingerprint] }
    struct Loop: Sendable { let role: String; let images: CursorAnimationImages }
    let role: String
    var releasing: Bool
    let frames: [Frame]
    var loops: [Loop] = []
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
                var animationSamples: [Int: CursorAnimationImages] = [:]
                var invalidAnimationCounts = Set<Int>()
                func matchesAnimation(_ expected: CursorAnimationImages) -> Bool {
                    let count = expected.count
                    if animationSamples[count] == nil && !invalidAnimationCounts.contains(count) {
                        animationSamples[count] = CursorAnimationImages.observation(image: snapshot.image, size: snapshot.size, hotSpot: snapshot.hotSpot, count: count)
                        if animationSamples[count] == nil { invalidAnimationCounts.insert(count) }
                    }
                    return animationSamples[count].map { expected.matches($0) } ?? false
                }
                if nativeAnimation.map(matchesAnimation) == true {
                    completion(snapshot.seed, nil, true, nil); return
                }
                if let recovery = nativeRecovery, let stale = recovery.loops.first(where: { matchesAnimation($0.images) }) {
                    // A foreground app can reselect its cached idle/hold strip
                    // after mouse-up. Identify its owner, but never acknowledge
                    // it as the current press/release or restart that timeline.
                    completion(snapshot.seed, CursorIdentification(roles: [stale.role]), false, nil); return
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
