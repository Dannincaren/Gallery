import AppKit
import GalleryCore
import GalleryNative

/// The WindowServer owns cursor position, Spaces and visibility. Gallery only
/// submits cached images. This renderer never hides the cursor or moves a window.
@MainActor
final class SystemCursorRenderer {
    private var maximumRasterScale = 2
    private var screenObserver: NSObjectProtocol?
    init() {
        refreshRasterScale()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRasterScale() }
            }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    private func refreshRasterScale() {
        maximumRasterScale = min(3, max(1, Int(ceil(NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 2))))
    }
    private struct Key: Hashable {
        let role: String, motion: Motion, image: ObjectIdentifier
        let geometry: CursorRasterGeometry
        let rasterScale: Int
    }
    private struct RasterKey: Hashable {
        let image: ObjectIdentifier, geometry: CursorRasterGeometry
        let rasterScale: Int, smooth: Bool, duration: Double
    }
    private struct Origin: Hashable { let role: String, motion: Motion }
    private var cache: [RasterKey: NSCursor] = [:]
    private var fingerprints: [RasterKey: CursorFingerprint] = [:]
    private var order: [RasterKey] = []
    private struct NativeFrame {
        let resource: GLCursorResource
        let slot: Int
        let bytes: Int
        let fingerprints: [CursorFingerprint]
        var origins: [Origin: Int]
        var identifier: String { "io.github.rp0902.gallery.frame.\(slot)" }
    }
    private struct LoopKey: Hashable { let focus: Focus; let offset: Int }
    private struct NativeLoop {
        let resource: GLCursorResource
        let images: CursorAnimationImages
        let bytes: Int
        let slot: Int
        var identifier: String { "io.github.rp0902.gallery.loop.\(slot)" }
    }
    private struct LoopBuild: @unchecked Sendable {
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
    private var independentNativeRoles = false
    private func roleFamily(_ id: String) -> String {
        independentNativeRoles ? NativeCursorCatalog.identity(id) : CursorCatalog.family(id)
    }
    private var nativeFrames: [RasterKey: NativeFrame] = [:]
    private struct FrameBuild: @unchecked Sendable {
        let resource: GLCursorResource
        let fingerprints: [CursorFingerprint]
        let bytes: Int
    }
    private let frameQueue = DispatchQueue(label: "Gallery.interaction-prepare", qos: .userInitiated)
    private var warmupRevision = 0
    private var warmupSignature: [Focus] = []
    private var playbackWarmupRevision = 0
    private var playbackWarmupJobs: [RasterKey: DispatchWorkItem] = [:]
    private var nativeFrameOrder: [RasterKey] = []
    private var guardedRaster: RasterKey?
    private var preferredRasters = Set<RasterKey>()
    private var frameBudget = CursorFrameCacheBudget(uniqueFrames: 0, bytesPerFrame: 0)
    private struct Focus: Hashable {
        let role: String, motion: Motion, geometry: CursorRasterGeometry
        let firstImage: ObjectIdentifier, count: Int, rasterScale: Int
        let duration: Double, smooth: Bool
    }
    private var focus: Focus?
    private var nextFrameSlot = 0
    private var freeFrameSlots: [Int] = []
    private var nativeFrameBytes = 0
    var expandedNativePlayback = true
    var onNativePlaybackReady: (() -> Void)?
    private let loopQueue = DispatchQueue(label: "Gallery.native-loop-prepare", qos: .userInitiated)
    private var loopEpoch = 0
    private var nativeLoops: [LoopKey: NativeLoop] = [:]
    private var loopOrder: [LoopKey] = []
    private var loopRecovery: [LoopKey: CursorRecoveryImages.Loop] = [:]
    private var loopRecoveryOrder: [LoopKey] = []
    private var loopBytes = 0
    private var nextLoopSlot = 0
    private var freeLoopSlots: [Int] = []
    private var failedLoops = Set<Focus>()
    private var preparingLoops = Set<LoopKey>()
    private var plannedLoop: (key: LoopKey, started: Double, step: Int)?
    private var activeLoop: (key: LoopKey, started: Double, startStep: Int, nextStep: Int?)?
    private(set) var nativeAnimationImages: CursorAnimationImages?
    private var recoveryCache: (role: String, geometry: CursorRasterGeometry, frames: [CursorRecoveryImages.Frame])?
    private struct ReleaseClock {
        let role: String, geometry: CursorRasterGeometry, started: Double, duration: Double, count: Int
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
    private(set) var testMainFrameBuilds = 0
    private(set) var testBackgroundFrameBuilds = 0
    var testPendingPlaybackBuilds: Int { playbackWarmupJobs.count }
    var testDelayedSeed = false
    var testUnselectedLoops = false
    var testNativeLoopCount: Int { nativeLoops.count }
    var testNativeLoopBytes: Int { loopBytes }
    var testPendingLoopBuilds: Int { preparingLoops.count }
    var testNativeLoopIdentifiers: [String] { nativeLoops.values.map(\.identifier) }
    func testPresentNativeLoop(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double = 1, started: Double, now: Double) -> Bool {
        precondition(testUnselectedLoops)
        guard NativeLoopWindow.eligible(count: prepared.frames.count, motion: motion, resize: CursorCatalog.isResize(role), expanded: expandedNativePlayback,
                                      visibleChanges: prepared.schedule.visibleChanges),
              prepared.uniqueImages.count > 1 else { return false }
        return presentLoop(prepared, role: role, motion: motion, geometry: CursorRasterGeometry(prepared.clip, scale: scale), started: started, now: now)
    }
    private(set) var frameRecords: [[String: Any]] = []
    func testGuardedIdentifiers(for role: String) -> [String] { guardedIdentifiers(for: role) }
    var testNativeFrameCount: Int { nativeFrames.count }
    var testNativeFrameBytes: Int { nativeFrameBytes }
    var testNativeFrameBudget: Int { frameBudget.bytes }
    var testRasterScale: Int {
        get { maximumRasterScale }
        set { maximumRasterScale = max(1, min(3, newValue)) }
    }
    /// Allocate only unselected, connection-local slots. This never publishes
    /// a global cursor or changes the user's displayed image.
    func testPrepareFrame(_ prepared: PreparedClip, index: Int, role: String, motion: Motion, scale: Double, focus active: Bool = true) throws -> Bool {
        let grid = CursorRasterGeometry(prepared.clip, scale: scale)
        let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), geometry: grid, rasterScale: maximumRasterScale)
        if active { focusFrames(prepared, key: key) }
        let raster = rasterKey(image: key.image, geometry: grid, duration: prepared.clip.frameDuration)
        let hit = nativeFrames[raster] != nil
        guard nativeFrame(prepared, index: index, key: key, geometry: grid.applying(to: prepared.clip)) != nil else {
            throw ThemeError.invalid("Could not prepare an unselected test frame")
        }
        return hit
    }
    func testRecoveryIndices(_ prepared: PreparedClip, role: String, scale: Double) -> [Int?] {
        let previous = guardedKey
        guardedKey = Key(role: role, motion: .release, image: ObjectIdentifier(prepared.frames[0].image),
            geometry: CursorRasterGeometry(prepared.clip, scale: scale), rasterScale: maximumRasterScale)
        defer { guardedKey = previous }
        return nativeRecoveryImages?.frames.map(\.releaseIndex) ?? []
    }
    func testRoleOwnershipIsIndependent(_ prepared: PreparedClip, scale: Double) -> Bool {
        let geometry = CursorRasterGeometry(prepared.clip, scale: scale), previous = lastKey
        let a = Key(role: "a", motion: .press, image: ObjectIdentifier(prepared.frames[0].image), geometry: geometry, rasterScale: maximumRasterScale)
        let b = Key(role: "b", motion: .press, image: a.image, geometry: geometry, rasterScale: maximumRasterScale)
        let seed = Int32.max
        defer { lastKey = previous; submittedSeeds.removeValue(forKey: seed); seedOrder.removeAll { $0 == seed } }
        lastKey = a; remember(seed: seed, key: a)
        guard owns(seed: seed) else { return false }
        lastKey = b
        return !owns(seed: seed)
    }
    #endif
    // Another app can reselect an older frame of this very same role. Only the
    // current image, motion and scale count as current ownership.
    func owns(seed: Int32) -> Bool { seed >= 0 && lastKey != nil && submittedSeeds[seed] == lastKey }
    func knownRole(seed: Int32) -> String? { submittedSeeds[seed]?.role }
    var nativeRecoveryImages: CursorRecoveryImages? {
        guard let key = guardedKey else { return nil }
        if recoveryCache?.role != key.role || recoveryCache?.geometry != key.geometry {
            let frames = nativeFrames.compactMap { raster, frame -> CursorRecoveryImages.Frame? in
                guard raster.geometry == key.geometry, frame.origins.keys.contains(where: { $0.role == key.role }) else { return nil }
                return CursorRecoveryImages.Frame(releaseIndex: frame.origins[Origin(role: key.role, motion: .release)], images: frame.fingerprints)
            }
            recoveryCache = (key.role, key.geometry, frames)
        }
        let loops = loopRecovery.sorted { a, b in
            if (a.key.focus.role == key.role) != (b.key.focus.role == key.role) { return a.key.focus.role == key.role }
            if a.key.focus.role != b.key.focus.role { return a.key.focus.role < b.key.focus.role }
            if a.key.focus.motion != b.key.focus.motion { return a.key.focus.motion.rawValue < b.key.focus.motion.rawValue }
            return a.key.offset < b.key.offset
        }.map(\.value)
        return CursorRecoveryImages(role: key.role, releasing: key.motion == .release, frames: recoveryCache?.frames ?? [], loops: loops)
    }
    func adoptReleaseFrame(_ index: Int, role: String, started: Double, now: Double, clip: CursorClip) {
        let geometry = releaseClock?.geometry ?? lastKey?.geometry ?? CursorRasterGeometry(clip)
        if releaseClock?.role != role || releaseClock?.started != started {
            releaseClock = ReleaseClock(role: role, geometry: geometry, started: started, duration: clip.frameDuration, count: clip.frames.count)
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
    func configureNativeNormals(_ dictionaries: [String: [String: Any]], visualClips: [String: CursorClip] = [:], smoothEdges: Bool = true,
                                independentRoles: Bool = false) {
        warmupRevision += 1; warmupSignature = []
        cancelPlaybackWarmup()
        independentNativeRoles = independentRoles
        self.smoothEdges = smoothEdges
        restoreNativeNormals(); clearNativeLoops(); nativeNormals.removeAll(); nativeAliases.removeAll(); nativeIDGroups.removeAll()
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
        for ids in equivalent.values {
            for id in ids { nativeAliases[id] = independentRoles ? ids.filter { roleFamily($0) == roleFamily(id) } : ids }
        }
        nativeIDGroups = Dictionary(grouping: nativeNormals.keys, by: roleFamily).mapValues {
            Set($0.flatMap { nativeAliases[$0] ?? [$0] }).sorted()
        }
    }
    private func rasterKey(image: ObjectIdentifier, geometry: CursorRasterGeometry, duration: Double) -> RasterKey {
        RasterKey(image: image, geometry: geometry, rasterScale: maximumRasterScale, smooth: smoothEdges, duration: duration)
    }
    private func focusFrames(_ prepared: PreparedClip, key: Key) {
        let next = Focus(role: key.role, motion: key.motion, geometry: key.geometry,
            firstImage: ObjectIdentifier(prepared.frames[0].image), count: prepared.frames.count,
            rasterScale: maximumRasterScale, duration: prepared.clip.frameDuration, smooth: smoothEdges)
        guard focus != next else { return }
        cancelPlaybackWarmup()
        focus = next
        let images = prepared.uniqueImages
        frameBudget = CursorFrameCacheBudget(uniqueFrames: images.count,
            bytesPerFrame: key.geometry.rasterBytes(maximumScale: maximumRasterScale))
        preferredRasters = frameBudget.retainsActiveClip ? Set(images.map {
            rasterKey(image: $0, geometry: key.geometry, duration: prepared.clip.frameDuration)
        }) : []
    }
    private func nativeFrame(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip) -> NativeFrame? {
        let raster = rasterKey(image: key.image, geometry: key.geometry, duration: geometry.frameDuration)
        let origin = Origin(role: key.role, motion: key.motion)
        if let frame = nativeFrames[raster] {
            if frame.origins[origin] == nil || index < frame.origins[origin]! {
                nativeFrames[raster]?.origins[origin] = index; recoveryCache = nil
            }
            nativeFrameOrder.removeAll { $0 == raster }; nativeFrameOrder.append(raster)
            return frame
        }
        #if GALLERY_RUNTIME_CHECKS
        testMainFrameBuilds += 1
        #endif
        guard let built = Self.buildFrame(prepared, index: index, geometry: geometry,
            rasterScale: maximumRasterScale, smooth: smoothEdges) else { return nil }
        return cacheFrame(built, prepared: prepared, index: index, key: key)
    }
    private nonisolated static func buildFrame(_ prepared: PreparedClip, index: Int, geometry: CursorClip,
                                              rasterScale: Int, smooth: Bool) -> FrameBuild? {
        // Paired images preserve the established WindowServer animation path.
        let source = prepared.frames[index].image
        guard let representations = try? CursorImages.rasters([source, source], width: geometry.width, height: geometry.height,
                smoothEdges: smooth, maximumScale: rasterScale),
              let resource = GLCursorBridge.prepareImages(representations, frameCount: 2, frameDuration: geometry.frameDuration,
                size: CGSize(width: geometry.width, height: geometry.height), hotSpot: CGPoint(x: geometry.hotX, y: geometry.hotY)) else { return nil }
        var fingerprints = representations.compactMap {
            CursorFingerprint(image: $0, width: geometry.width, height: geometry.height * 2, hotX: geometry.hotX, hotY: geometry.hotY)
        }
        if let original = CursorFingerprint(image: source, width: geometry.width, height: geometry.height,
            hotX: geometry.hotX, hotY: geometry.hotY) { fingerprints.append(original) }
        return FrameBuild(resource: resource, fingerprints: fingerprints,
            bytes: representations.reduce(0) { $0 + $1.bytesPerRow * $1.height })
    }
    private func cacheFrame(_ built: FrameBuild, prepared: PreparedClip, index: Int, key: Key) -> NativeFrame? {
        let raster = rasterKey(image: key.image, geometry: key.geometry, duration: prepared.clip.frameDuration)
        let origin = Origin(role: key.role, motion: key.motion)
        if let frame = nativeFrames[raster] { return frame }
        let bytes = built.bytes
        while nativeFrames.count >= frameBudget.count || (nativeFrameBytes + bytes > frameBudget.bytes && !nativeFrames.isEmpty) {
            guard let oldest = nativeFrameOrder.first(where: { $0 != guardedRaster && !preferredRasters.contains($0) })
                    ?? nativeFrameOrder.first(where: { $0 != guardedRaster }),
                  let frame = nativeFrames.removeValue(forKey: oldest) else { break }
            nativeFrameOrder.removeAll { $0 == oldest }; nativeFrameBytes -= frame.bytes
            clearSlots([frame.identifier]); freeFrameSlots.append(frame.slot)
        }
        let slot: Int
        if let reused = freeFrameSlots.popLast() { slot = reused }
        else { slot = nextFrameSlot; nextFrameSlot += 1 }
        let identifier = "io.github.rp0902.gallery.frame.\(slot)"
        guard GLCursorBridge.storePreparedCursor(built.resource, identifiers: [identifier], globally: false) == 0 else {
            freeFrameSlots.append(slot); return nil
        }
        let frame = NativeFrame(resource: built.resource, slot: slot, bytes: bytes, fingerprints: built.fingerprints, origins: [origin: index])
        nativeFrames[raster] = frame; nativeFrameOrder.append(raster); nativeFrameBytes += bytes
        recoveryCache = nil
        return frame
    }
    private func guardedIdentifiers(for role: String) -> [String] { nativeIDGroups[roleFamily(role)] ?? [] }
    func warmInteraction(_ prepared: PreparedClip, role: String, motion: Motion, scale: Double, limit: Int = 24) {
        if motion == .normal && (2...24).contains(prepared.frames.count) && !CursorCatalog.isResize(role) { return }
        let grid = CursorRasterGeometry(prepared.clip, scale: scale)
        let geometry = grid.applying(to: prepared.clip)
        var warmed = Set<ObjectIdentifier>()
        for index in prepared.frames.indices {
            guard warmed.count < limit else { break }
            guard warmed.insert(ObjectIdentifier(prepared.frames[index].image)).inserted else { continue }
            let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), geometry: grid, rasterScale: maximumRasterScale)
            _ = nativeFrame(prepared, index: index, key: key, geometry: geometry)
        }
    }
    func warmInteractions(_ clips: [(Motion, PreparedClip)], role: String, scale: Double) {
        let signature = clips.map { motion, clip in
            loopFocus(clip, role: role, motion: motion, grid: CursorRasterGeometry(clip.clip, scale: scale))
        }
        guard signature != warmupSignature else { return }
        warmupSignature = signature; warmupRevision += 1
        let revision = warmupRevision
        var jobs: [(Motion, PreparedClip, Int)] = [], rasters = Set<RasterKey>(), cost = 0
        // Interleave motions so the beginning of release is not queued behind
        // an entire long press clip. Identical frames share immutable resources.
        for index in 0..<(clips.map { $0.1.frames.count }.max() ?? 0) {
            for (motion, clip) in clips where index < clip.frames.count {
                let grid = CursorRasterGeometry(clip.clip, scale: scale)
                let key = rasterKey(image: ObjectIdentifier(clip.frames[index].image), geometry: grid, duration: clip.clip.frameDuration)
                guard nativeFrames[key] == nil, rasters.insert(key).inserted else { continue }
                let bytes = grid.rasterBytes(maximumScale: maximumRasterScale)
                guard cost + bytes <= CursorFrameCacheBudget.baseBytes - 4 * 1024 * 1024 else { continue }
                cost += bytes; jobs.append((motion, clip, index))
            }
        }
        warmNext(jobs, offset: 0, role: role, scale: scale, revision: revision)
    }
    func cancelInteractionWarmup() {
        warmupRevision += 1; warmupSignature = []
    }
    private func cancelPlaybackWarmup() {
        playbackWarmupRevision += 1
        playbackWarmupJobs.values.forEach { $0.cancel() }
        playbackWarmupJobs.removeAll()
    }
    private func warmPlayback(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip) {
        guard key.motion.loops, prepared.frames.count > NativeLoopWindow.limit else { return }
        // Large idle clips cannot fit a whole cycle in the raster budget.
        // Prepare just the next three visible changes off the main thread;
        // repeated source frames do not create jobs or extra timer wakeups.
        var step = index
        let revision = playbackWarmupRevision, expectedFocus = focus
        let rasterScale = maximumRasterScale, smooth = smoothEdges
        for _ in 0..<3 {
            guard let next = prepared.schedule.nextChange(after: step, looping: true) else { break }
            step = next
            let upcoming = next % prepared.frames.count
            let image = ObjectIdentifier(prepared.frames[upcoming].image)
            let raster = rasterKey(image: image, geometry: key.geometry, duration: prepared.clip.frameDuration)
            guard nativeFrames[raster] == nil, playbackWarmupJobs[raster] == nil else { continue }
            guard playbackWarmupJobs.count < 3,
                  key.geometry.rasterBytes(maximumScale: rasterScale) <= frameBudget.bytes / 4 else { break }
            let upcomingKey = Key(role: key.role, motion: key.motion, image: image, geometry: key.geometry, rasterScale: rasterScale)
            let task = DispatchWorkItem { [weak self] in
                let built = autoreleasepool { Self.buildFrame(prepared, index: upcoming, geometry: geometry, rasterScale: rasterScale, smooth: smooth) }
                DispatchQueue.main.async {
                    guard let self, self.playbackWarmupRevision == revision, self.focus == expectedFocus else { return }
                    self.playbackWarmupJobs.removeValue(forKey: raster)
                    guard let built else { return }
                    _ = self.cacheFrame(built, prepared: prepared, index: upcoming, key: upcomingKey)
                    #if GALLERY_RUNTIME_CHECKS
                    self.testBackgroundFrameBuilds += 1
                    #endif
                }
            }
            playbackWarmupJobs[raster] = task
            frameQueue.async(execute: task)
        }
    }
    private func warmNext(_ jobs: [(Motion, PreparedClip, Int)], offset: Int, role: String, scale: Double, revision: Int) {
        guard warmupRevision == revision, offset < jobs.count else { return }
        let (motion, clip, index) = jobs[offset]
        let grid = CursorRasterGeometry(clip.clip, scale: scale)
        let key = Key(role: role, motion: motion, image: ObjectIdentifier(clip.frames[index].image), geometry: grid, rasterScale: maximumRasterScale)
        let geometry = grid.applying(to: clip.clip), smooth = smoothEdges, rasterScale = maximumRasterScale
        frameQueue.async { [weak self] in
            let built = autoreleasepool { Self.buildFrame(clip, index: index, geometry: geometry, rasterScale: rasterScale, smooth: smooth) }
            DispatchQueue.main.async {
                guard let self, self.warmupRevision == revision else { return }
                if let built, self.nativeFrames.count < self.frameBudget.count,
                   self.nativeFrameBytes + built.bytes <= self.frameBudget.bytes {
                    _ = self.cacheFrame(built, prepared: clip, index: index, key: key)
                    #if GALLERY_RUNTIME_CHECKS
                    self.testBackgroundFrameBuilds += 1
                    #endif
                }
                self.warmNext(jobs, offset: offset + 1, role: role, scale: scale, revision: revision)
            }
        }
    }
    private func restoreNativeNormals() {
        let groups = Dictionary(grouping: guardedIDs.filter { nativeNormals[$0] != nil }, by: { ObjectIdentifier(nativeNormals[$0]!) })
        if publishesNativeLoops {
            for ids in groups.values { _ = GLCursorBridge.storePreparedCursor(nativeNormals[ids[0]]!, identifiers: ids, globally: true) }
        }
        guardedIDs.removeAll(); guardedKey = nil; guardedRaster = nil; nativeGuardFingerprints.removeAll()
        nativeAnimationImages = nil; activeLoop = nil; nativeSyncPending = false
    }
    private func synchronizeNative(_ prepared: PreparedClip, index: Int, key: Key, geometry: CursorClip, enabled: Bool,
                                   started: Double, now: Double) -> Bool {
        let synchronized = key.motion != .normal || (prepared.frames.count > 1 && !CursorCatalog.isResize(key.role))
        guard enabled, synchronized else { if !guardedIDs.isEmpty { restoreNativeNormals() }; return false }
        guard !publishesNativeLoops || GLCursorBridge.cursorVisibility() != 0 else { return false }
        let ids = guardedIdentifiers(for: key.role)
        guard !ids.isEmpty else { return false }
        if guardedKey == key && activeLoop == nil && (owns(seed: GLCursorBridge.cursorSeed()) || nativeSyncPending) { return true }
        focusFrames(prepared, key: key)
        warmPlayback(prepared, index: index, key: key, geometry: geometry)
        guard let frame = nativeFrame(prepared, index: index, key: key, geometry: geometry) else { return false }
        if publishesNativeLoops && !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return false }
            backgroundOwned = true
        }
        // Show the immutable, already cached slot FIRST. Updating every system
        // alias must not sit in front of the visible button response.
        #if GALLERY_RUNTIME_CHECKS
        let begin = ProcessInfo.processInfo.systemUptime
        #endif
        if publishesNativeLoops {
            guard GLCursorBridge.selectCursorIdentifier(frame.identifier) == 0 else { return false }
        }
        #if GALLERY_RUNTIME_CHECKS
        let selectedAt = ProcessInfo.processInfo.systemUptime
        #endif
        if guardedIDs != ids { restoreNativeNormals() }
        guardedIDs = ids
        if publishesNativeLoops {
            guard GLCursorBridge.storePreparedCursor(frame.resource, identifiers: ids, globally: true) == 0 else {
                restoreNativeNormals(); return false
            }
        }
        activeLoop = nil; nativeAnimationImages = nil
        guardedKey = key; guardedRaster = rasterKey(image: key.image, geometry: key.geometry, duration: geometry.frameDuration)
        nativeGuardFingerprints = frame.fingerprints
        nativeSyncPending = true
        submissionRevision += 1; pendingImage = nil; lastKey = key; submissions += 1
        #if GALLERY_RUNTIME_CHECKS
        let completed = ProcessInfo.processInfo.systemUptime
        frameRecords.append(["role": key.role, "motion": key.motion.rawValue, "index": index, "started": started, "at": now,
            "nativePaired": true, "selectedAt": selectedAt, "completedAt": completed,
            "selectMs": (selectedAt - begin) * 1000, "submitMs": (completed - begin) * 1000,
            "width": size.width, "height": size.height])
        if frameRecords.count > 500 { frameRecords.removeFirst() }
        #endif
        return true
    }
    private var publishesNativeLoops: Bool {
        #if GALLERY_RUNTIME_CHECKS
        return !testUnselectedLoops
        #else
        return true
        #endif
    }
    private func loopFocus(_ prepared: PreparedClip, role: String, motion: Motion, grid: CursorRasterGeometry) -> Focus {
        Focus(role: role, motion: motion, geometry: grid, firstImage: ObjectIdentifier(prepared.frames[0].image),
            count: prepared.frames.count, rasterScale: maximumRasterScale, duration: prepared.clip.frameDuration, smooth: smoothEdges)
    }
    private nonisolated static func buildLoop(_ prepared: PreparedClip, focus: Focus, offset: Int) -> LoopBuild? {
        let count = min(NativeLoopWindow.limit, prepared.frames.count)
        let frames = (0..<count).map { prepared.frames[(offset + $0) % prepared.frames.count].image }
        guard let rasters = try? CursorImages.rasters(frames, width: focus.geometry.width, height: focus.geometry.height,
                    smoothEdges: focus.smooth, maximumScale: focus.rasterScale),
              let resource = GLCursorBridge.prepareImages(rasters, frameCount: UInt(count), frameDuration: focus.duration,
                    size: CGSize(width: focus.geometry.width, height: focus.geometry.height), hotSpot: CGPoint(x: focus.geometry.hotX, y: focus.geometry.hotY)),
              let images = CursorAnimationImages(images: rasters, count: count, size: CGSize(width: focus.geometry.width, height: focus.geometry.height),
                    hotSpot: CGPoint(x: focus.geometry.hotX, y: focus.geometry.hotY)) else { return nil }
        return LoopBuild(resource: resource, images: images, bytes: rasters.reduce(0) { $0 + $1.bytesPerRow * $1.height })
    }
    private func requestLoop(_ key: LoopKey, prepared: PreparedClip) {
        guard nativeLoops[key] == nil, !preparingLoops.contains(key), preparingLoops.count < 2, !failedLoops.contains(key.focus) else { return }
        let estimate = key.focus.geometry.rasterBytes(maximumScale: key.focus.rasterScale, frameCount: min(NativeLoopWindow.limit, key.focus.count))
        let protectedBytes = activeLoop.flatMap { nativeLoops[$0.key]?.bytes } ?? 0
        guard estimate + protectedBytes <= CursorFrameCacheBudget.maximumBytes else { return }
        preparingLoops.insert(key)
        let epoch = loopEpoch
        loopQueue.async { [weak self] in
            let built = autoreleasepool { Self.buildLoop(prepared, focus: key.focus, offset: key.offset) }
            DispatchQueue.main.async {
                guard let self, self.loopEpoch == epoch else { return }
                self.preparingLoops.remove(key)
                guard let built else { self.failedLoops.insert(key.focus); return }
                guard self.cacheLoop(built, for: key) else { return }
                if self.plannedLoop?.key == key { self.onNativePlaybackReady?() }
            }
        }
    }
    private func cacheLoop(_ built: LoopBuild, for key: LoopKey) -> Bool {
        if nativeLoops[key] != nil { return true }
        while nativeLoops.count >= 16 || loopBytes + built.bytes > CursorFrameCacheBudget.maximumBytes {
            guard let oldest = loopOrder.first(where: { $0 != activeLoop?.key && $0 != plannedLoop?.key }),
                  let old = nativeLoops.removeValue(forKey: oldest) else { return false }
            loopOrder.removeAll { $0 == oldest }; loopBytes -= old.bytes
            let identity = ObjectIdentifier(old.resource)
            let staleSeeds = Set(submittedSeeds.filter { $0.value.image == identity }.keys)
            staleSeeds.forEach { submittedSeeds.removeValue(forKey: $0) }; seedOrder.removeAll { staleSeeds.contains($0) }
            clearSlots([old.identifier]); freeLoopSlots.append(old.slot)
        }
        let slot: Int
        if let reused = freeLoopSlots.popLast() { slot = reused } else { slot = nextLoopSlot; nextLoopSlot += 1 }
        let loop = NativeLoop(resource: built.resource, images: built.images, bytes: built.bytes, slot: slot)
        guard GLCursorBridge.storePreparedCursor(loop.resource, identifiers: [loop.identifier], globally: false) == 0 else {
            freeLoopSlots.append(slot); failedLoops.insert(key.focus); return false
        }
        nativeLoops[key] = loop; loopOrder.append(key); loopBytes += built.bytes
        return true
    }
    private func planLoop(_ prepared: PreparedClip, focus: Focus, started: Double, step: Int) {
        let key = LoopKey(focus: focus, offset: step % prepared.frames.count)
        plannedLoop = (key, started, step)
        requestLoop(key, prepared: prepared)
        // A second precomputed phase can absorb a one-source-frame late wakeup.
        // Large rasters keep just the primary lookahead inside the same bound.
        let bytes = focus.geometry.rasterBytes(maximumScale: focus.rasterScale, frameCount: min(NativeLoopWindow.limit, focus.count))
        if bytes * 3 <= CursorFrameCacheBudget.maximumBytes {
            requestLoop(LoopKey(focus: focus, offset: (step + 1) % prepared.frames.count), prepared: prepared)
        }
    }
    private func presentLoop(_ prepared: PreparedClip, role: String, motion: Motion, geometry grid: CursorRasterGeometry, started: Double, now: Double) -> Bool {
        let focus = loopFocus(prepared, role: role, motion: motion, grid: grid)
        guard !failedLoops.contains(focus) else { plannedLoop = nil; return false }
        let step = max(0, Int((max(0, now - started) + 0.0000001) / prepared.clip.frameDuration))
        let index = step % prepared.frames.count
        size = CGSize(width: grid.width, height: grid.height); displayedFrame = prepared.frames[index].data
        if let active = activeLoop, active.key.focus == focus, active.started == started, step >= active.startStep,
           active.nextStep.map({ step < $0 }) ?? true,
           !publishesNativeLoops || owns(seed: GLCursorBridge.cursorSeed()) || nativeSyncPending {
            nextFrameDeadline = active.nextStep.map { started + Double($0) * focus.duration }
            return true
        }
        let cacheKey = LoopKey(focus: focus, offset: index)
        guard let loop = nativeLoops[cacheKey] else {
            if plannedLoop?.key.focus != focus || plannedLoop?.started != started || (plannedLoop?.step ?? -1) < step {
                planLoop(prepared, focus: focus, started: started, step: step + NativeLoopWindow.preparationLead(frameDuration: focus.duration))
            }
            return false
        }
        // Distinct immutable strips need distinct ownership identities. A seed
        // from an earlier segment must not acknowledge the current segment.
        let key = Key(role: role, motion: motion, image: ObjectIdentifier(loop.resource), geometry: grid, rasterScale: maximumRasterScale)
        guard !publishesNativeLoops || GLCursorBridge.cursorVisibility() != 0 else { return false }
        let ids = guardedIdentifiers(for: role)
        guard !ids.isEmpty else { return false }
        if guardedIDs != ids { restoreNativeNormals() }
        if publishesNativeLoops {
            if !backgroundOwned {
                guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return false }; backgroundOwned = true
            }
            // Select a prebuilt immutable slot before publishing its aliases.
            guard GLCursorBridge.selectCursorIdentifier(loop.identifier) == 0,
                  GLCursorBridge.storePreparedCursor(loop.resource, identifiers: ids, globally: true) == 0 else {
                failedLoops.insert(focus); restoreNativeNormals(); return false
            }
        }
        let window = NativeLoopWindow(sourceCount: prepared.frames.count, startStep: step)!
        loopOrder.removeAll { $0 == cacheKey }; loopOrder.append(cacheKey)
        guardedIDs = ids; guardedKey = key; guardedRaster = nil; lastKey = key
        activeLoop = (cacheKey, started, step, window.nextStep)
        loopRecovery[cacheKey] = CursorRecoveryImages.Loop(role: role, images: loop.images)
        loopRecoveryOrder.removeAll { $0 == cacheKey }; loopRecoveryOrder.append(cacheKey)
        if loopRecoveryOrder.count > 64 { loopRecovery.removeValue(forKey: loopRecoveryOrder.removeFirst()) }
        nativeAnimationImages = loop.images; nativeGuardFingerprints = []
        pendingImage = nil; nativeSyncPending = true
        nextFrameDeadline = window.nextStep.map { started + Double($0) * focus.duration }
        submissionRevision += 1; submissions += 1
        plannedLoop = nil
        if let next = window.nextStep { planLoop(prepared, focus: focus, started: started, step: next) }
        #if GALLERY_RUNTIME_CHECKS
        frameRecords.append(["role": role, "motion": motion.rawValue, "index": index, "started": started, "at": now,
            "nativeLoop": true, "segmented": window.nextStep != nil, "count": window.count, "sourceCount": prepared.frames.count,
            "width": size.width, "height": size.height, "global": publishesNativeLoops])
        if frameRecords.count > 500 { frameRecords.removeFirst() }
        #endif
        return true
    }
    private func clearNativeLoops() {
        loopEpoch += 1; preparingLoops.removeAll(); plannedLoop = nil
        clearSlots(nativeLoops.values.map(\.identifier))
        nativeLoops.removeAll(); loopOrder.removeAll(); failedLoops.removeAll(); loopBytes = 0
        loopRecovery.removeAll(); loopRecoveryOrder.removeAll()
        freeLoopSlots.removeAll(); nextLoopSlot = 0; activeLoop = nil
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
        if shellOverride != shell {
            if publishesNativeLoops { GLCursorBridge.setDockCursorOverride(shell) }
            shellOverride = shell
        }
        let clip = prepared.clip
        let grid = CursorRasterGeometry(clip, scale: scale)
        let mayLoop = !staticOnly && !shell && synchronizeRegistration && prepared.uniqueImages.count > 1
            && NativeLoopWindow.eligible(count: prepared.frames.count, motion: motion, resize: CursorCatalog.isResize(role), expanded: expandedNativePlayback,
                                         visibleChanges: prepared.schedule.visibleChanges)
        if mayLoop {
            if presentLoop(prepared, role: role, motion: motion, geometry: grid, started: started, now: now) { return }
        } else { plannedLoop = nil }

        var displayStart = started
        if motion == .release && !staticOnly {
            if releaseClock?.role != role || releaseClock?.started != started || releaseClock?.geometry != grid {
                releaseClock = ReleaseClock(role: role, geometry: grid, started: started, duration: clip.frameDuration, count: clip.frames.count)
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
        if let planned = plannedLoop, planned.started == started {
            let due = started + Double(planned.step) * clip.frameDuration
            if due > now { nextFrameDeadline = min(nextFrameDeadline ?? due, due) }
        }
        let key = Key(role: role, motion: motion, image: ObjectIdentifier(prepared.frames[index].image), geometry: grid, rasterScale: maximumRasterScale)
        let geometry = grid.applying(to: clip)
        size = CGSize(width: geometry.width, height: geometry.height); displayedFrame = prepared.frames[index].data
        if synchronizeNative(prepared, index: index, key: key, geometry: geometry, enabled: synchronizeRegistration && !staticOnly,
                             started: started, now: now) { return }
        let seed = GLCursorBridge.cursorSeed()
        if lastKey == key && (owns(seed: seed) || pendingImage != nil) { return }
        // Respect cursor hiding owned by the foreground app (typing, games).
        // There are no Gallery hide tickets to accumulate or recover here.
        guard !publishesNativeLoops || GLCursorBridge.cursorVisibility() != 0 else { return }
        let raster = rasterKey(image: key.image, geometry: grid, duration: 0)
        let cursor: NSCursor
        if let existing = cache[raster] { cursor = existing }
        else {
            cursor = NSCursor(image: cursorImage(prepared.frames[index].image, size: size),
                              hotSpot: NSPoint(x: geometry.hotX, y: geometry.hotY))
            cache[raster] = cursor; order.append(raster)
            if order.count > 256 { let oldest = order.removeFirst(); cache.removeValue(forKey: oldest); fingerprints.removeValue(forKey: oldest) }
        }
        if publishesNativeLoops && !backgroundOwned {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { return }
            backgroundOwned = true
        }
        let before = GLCursorBridge.cursorSeed()
        let actual = publishesNativeLoops ? GLCursorBridge.present(cursor) : before
        #if GALLERY_RUNTIME_CHECKS
        let returned = testDelayedSeed ? before : actual
        #else
        let returned = actual
        #endif
        submissionRevision += 1; pendingImage = nil
        if returned >= 0 && returned != before { remember(seed: returned, key: key) }
        else {
            if fingerprints[raster] == nil {
                if let rep = cursor.image.representations.first as? NSBitmapImageRep, let bitmap = rep.cgImage {
                    fingerprints[raster] = CursorFingerprint(image: bitmap,
                        width: geometry.width, height: geometry.height, hotX: geometry.hotX, hotY: geometry.hotY)
                }
            }
            if let fingerprint = fingerprints[raster] { pendingImage = (submissionRevision, fingerprint) }
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
        if let rasters = try? CursorImages.rasters([source], width: size.width, height: size.height, smoothEdges: smoothEdges, maximumScale: maximumRasterScale) {
            for raster in rasters {
                let rep = NSBitmapImageRep(cgImage: raster); rep.size = size; image.addRepresentation(rep)
            }
        }
        return image.representations.isEmpty ? NSImage(cgImage: source, size: size) : image
    }
    func passThrough(frame: Data? = nil, size: CGSize = .zero) {
        cancelPlaybackWarmup()
        if shellOverride {
            if publishesNativeLoops { GLCursorBridge.setDockCursorOverride(false) }
            shellOverride = false
        }
        restoreNativeNormals()
        if backgroundOwned { _ = GLCursorBridge.setBackgroundCursorUpdates(false); backgroundOwned = false }
        plannedLoop = nil
        lastKey = nil; pendingImage = nil; nextFrameDeadline = nil; displayedFrame = frame; self.size = size
        releaseClock = nil
    }
    func stop(restoring original: [String: Any]?) {
        warmupRevision += 1; warmupSignature = []
        if backgroundOwned, let original, let clip = try? CursorImages.fromCape(original),
           let data = clip.frames.first, let image = try? CursorImages.bitmap(data) {
            let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: clip.width, height: clip.height)),
                                  hotSpot: NSPoint(x: clip.hotX, y: clip.hotY))
            _ = GLCursorBridge.present(cursor)
        }
        passThrough(); cache.removeAll(); fingerprints.removeAll(); order.removeAll(); submittedSeeds.removeAll(); seedOrder.removeAll()
        clearSlots((0..<nextFrameSlot).map { "io.github.rp0902.gallery.frame.\($0)" })
        clearNativeLoops()
        nativeFrames.removeAll(); nativeFrameOrder.removeAll(); nativeNormals.removeAll(); nativeAliases.removeAll(); nativeIDGroups.removeAll()
        preferredRasters.removeAll(); focus = nil; frameBudget = CursorFrameCacheBudget(uniqueFrames: 0, bytesPerFrame: 0)
        nativeFrameBytes = 0; nextFrameSlot = 0; freeFrameSlots.removeAll()
        recoveryCache = nil
    }
}
