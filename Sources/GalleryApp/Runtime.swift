import AppKit
import Combine
import GalleryCore
import GalleryNative

/// One source and one pending deadline. Animation/confirmation work opts into
/// strict delivery; watchdogs retain leeway. No repeating frame-rate polling.
@MainActor
final class CursorDeadlineTimer {
    private static let preciseQueue = DispatchQueue(label: "Gallery.animation-deadline", qos: .userInteractive)
    private static let relaxedQueue = DispatchQueue(label: "Gallery.watchdog-deadline", qos: .utility)
    private var source: DispatchSourceTimer?
    private var revision = 0
    private(set) var deadline: Double?
    private(set) var precise = false
    #if GALLERY_RUNTIME_CHECKS
    private(set) var testSignalAt = 0.0
    #endif
    @discardableResult
    func arm(at requested: Double, precise requestedPrecision: Bool, action: @escaping (Double) -> Void) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let deadline, deadline <= requested, precise || !requestedPrecision { return false }
        // Promote an already earlier watchdog to strict timing when an input
        // creates an animation. Retaining its relaxed source could defer it.
        let due = max(now + 0.001, min(deadline ?? requested, requested))
        cancel()
        let epoch = revision
        let timer = DispatchSource.makeTimerSource(flags: requestedPrecision ? .strict : [],
            queue: requestedPrecision ? Self.preciseQueue : Self.relaxedQueue)
        source = timer; deadline = due; precise = requestedPrecision
        timer.setEventHandler { [weak self] in
            #if GALLERY_RUNTIME_CHECKS
            let signaledAt = ProcessInfo.processInfo.systemUptime
            #endif
            // A nested AppKit import/export dialog must keep receiving frame
            // deadlines even when it was opened from a main-queue callback.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    guard let self, self.revision == epoch else { return }
                    #if GALLERY_RUNTIME_CHECKS
                    self.testSignalAt = signaledAt
                    #endif
                    self.source?.cancel(); self.source = nil; self.deadline = nil; self.precise = false
                    action(due)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let delay = max(0.001, due - ProcessInfo.processInfo.systemUptime)
        let leeway = requestedPrecision ? 0 : Int(min(0.02, delay * 0.1) * 1_000_000_000)
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: .nanoseconds(leeway))
        timer.resume()
        return true
    }
    func cancel() {
        revision += 1; source?.cancel(); source = nil; deadline = nil; precise = false
    }
    deinit { source?.cancel() }
}

@MainActor
final class CursorRuntime: ObservableObject {
    @Published private(set) var enabled = false
    let statusDisplay = RuntimeStatus(L("未启用 · 编辑与预览不会更改系统光标"))
    private(set) var status: String {
        get { statusDisplay.text }
        set { statusDisplay.set(newValue) }
    }
    private struct StatusKey: Equatable {
        let role: String, motion: Motion
        let shell: Bool, native: Bool, shellClick: Bool
    }
    private var statusKey: StatusKey?
    @Published var error: String?
    @Published private(set) var unsupportedRoles: [String: String] = [:]
    private var theme: GalleryTheme?
    private var roles: [String: CursorRole] = [:]
    private var canonicalRoles: [String: String] = [:]
    private var prepared: PreparedCursors?
    private let renderer = SystemCursorRenderer()
    private let waitOverlay: WaitCursorOverlay
    private var waitRoleID: String?
    private let nativeWait: Bool
    private var originalWait: [String: Any]?
    private var nativeWaitActive = false
    private var originals: [String: [String: Any]] = [:]
    private var normal: [String: [String: Any]] = [:]
    private var normalVisualClips: [String: CursorClip] = [:]
    private var recognition: CursorRecognition?
    private var recognizing = false
    private var generation = 0
    private var roleID: String?
    private var roleRevision = 0
    private var roleAliases: [String] = []
    private var machine = RoleInteractionMachine(now: ProcessInfo.processInfo.systemUptime)
    private var normalClocks = RoleAnimationClocks()
    private let timer = CursorDeadlineTimer()
    private let confirmationTimer = CursorDeadlineTimer()
    private var confirmationDue: Double?
    private var confirmation = CursorConfirmationBackoff()
    private let observation = MouseObservation()
    private let scenes = SystemSceneMonitor()
    private var lastLocation = NSEvent.mouseLocation
    private var lastScroll: UInt32 = 0
    private var inputCounters = MouseCounterLedger(downs: 0, ups: 0)
    private var lastScrollCheck = 0.0
    private var lastWatchdog = 0.0
    private var lastCornerCheck = 0.0
    private var counterGesture = false
    private var dockGesture = false
    private var lastLeftEdge = -Double.infinity
    private var lastLeftDown = 0.0
    private var lastLeftUp = 0.0
    private var unknownSince: Double?
    private var registeredMatch = false
    private var registeredScales: [String: Double] = [:]
    private var shake = PointerShake()
    private var shakeEnabled = false
    private var editorCorner = ResizeCornerLatch()
    private(set) var tickCount = 0
    #if GALLERY_RUNTIME_CHECKS
    private var inputRecords: [[String: Any]] = []
    private var renderRecords: [[String: Any]] = []
    private var observationRecords: [[String: Any]] = []
    private var rawInputRecords: [[String: Any]] = []
    private var lastRecordedPhase = ""
    private(set) var testRenderCalls = 0
    private(set) var testTimerCreations = 0
    private var timingTrace: [[String: Any]] = []
    private var tracingTiming = false
    func testStartTimingTrace() {
        timingTrace.removeAll(keepingCapacity: true); tracingTiming = true
        scenes.testRecords.removeAll(); scenes.testTracing = true
    }
    func testFinishTimingTrace() -> [String: Any] {
        tracingTiming = false
        scenes.testTracing = false
        return ["events": timingTrace, "runtime": testStats,
                "scenes": scenes.testRecords,
                "mainRasterBuilds": renderer.testMainFrameBuilds, "backgroundRasterBuilds": renderer.testBackgroundFrameBuilds]
    }
    private func traceTiming(_ event: String, _ details: [String: Any]) {
        guard tracingTiming, timingTrace.count < 6000 else { return }
        var row = details; row["event"] = event; row["at"] = now
        timingTrace.append(row)
    }
    #endif
    private var activity: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var suspended = false
    private var locked = false
    private var excluded = false
    private var wasPaused = false
    private var lastProbe = 0.0
    private var lastSeed: Int32 = -1
    private var pointerScale = 1.0
    private let registrationQueue = DispatchQueue(label: "Gallery.cursor-size", qos: .userInitiated)
    private var pendingRegistration: DispatchWorkItem?
    private var registrationRevision = 0
    private var dirtyRegistrationIDs = Set<String>()
    private var recoveryOverride: URL?
    private let acquireSession: (() throws -> Void)?
    private let releaseSession: (() -> Void)?
    private var ownsSession = false
    init(recoveryURL: URL? = nil, waitOverlay: WaitCursorOverlay? = nil, expandedNativePlayback: Bool = true,
         acquireSession: (() throws -> Void)? = nil, releaseSession: (() -> Void)? = nil) {
        recoveryOverride = recoveryURL; self.waitOverlay = waitOverlay ?? WaitCursorOverlay()
        nativeWait = waitOverlay == nil
        self.acquireSession = acquireSession; self.releaseSession = releaseSession
        renderer.expandedNativePlayback = expandedNativePlayback
        renderer.onNativePlaybackReady = { [weak self] in
            guard let self, self.enabled, !self.paused else { return }
            self.render(); self.scheduleNext()
        }
    }
    func setScale(_ value: Double) {
        guard value.isFinite else { return }
        pointerScale = min(3, max(0.25, value)); updateWaitScale()
        registeredMatch = false; render(); scheduleNext(); scheduleSizeRegistration()
    }
    func setRoleScale(_ value: Double, for identifier: String) {
        guard value.isFinite, roles[identifier] != nil else { return }
        let family = roleFamily(identifier)
        for id in roles.keys where roleFamily(id) == family { roles[id]?.scale = min(3, max(0.25, value)) }
        updateWaitScale()
        registeredMatch = false; render(); scheduleNext(); scheduleSizeRegistration(family: family)
    }
    private func scheduleSizeRegistration(family: String? = nil) {
        guard enabled, let theme else { return }
        dirtyRegistrationIDs.formUnion(normal.keys.filter { family == nil || roleFamily($0) == family })
        pendingRegistration?.cancel(); registrationRevision += 1
        let revision = registrationRevision, currentGeneration = generation, scale = pointerScale
        let selected = roles.values.filter { dirtyRegistrationIDs.contains($0.id) }
        let smoothing = theme.appearance.effectiveSmoothEdges
        let task = DispatchWorkItem { [weak self] in
            let result = Result { () -> ([String: [String: Any]], [String: CursorClip], [String: Double]) in
                var base: [String: [String: Any]] = [:], visuals: [String: CursorClip] = [:], scales: [String: Double] = [:]
                var encoded: [(CursorClip, [String: Any])] = []
                for role in selected {
                    let factor = scale * role.scale
                    var clip = role.clip(.normal)!.scaled(by: factor).alignedToPixels()
                    visuals[role.id] = clip; scales[role.id] = factor
                    if clip.frames.count > 1 && !CursorCatalog.isResize(role.id) && NativeCursorCatalog.identity(role.id) != CursorRestoreJournal.waitID { clip.frames = [clip.frames[0]] }
                    if let cached = encoded.first(where: { $0.0 == clip }) { base[role.id] = cached.1 }
                    else {
                        let dictionary = try CursorImages.capeDictionary(clip, smoothEdges: smoothing)
                        encoded.append((clip, dictionary)); base[role.id] = dictionary
                    }
                }
                return (base, visuals, scales)
            }
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == currentGeneration, self.registrationRevision == revision else { return }
                switch result {
                case .success(let resources): self.commitSizes(resources, generation: currentGeneration, revision: revision)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        pendingRegistration = task
        registrationQueue.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    private func commitSizes(_ resources: ([String: [String: Any]], [String: CursorClip], [String: Double]), generation: Int, revision: Int) {
        guard enabled, self.generation == generation, registrationRevision == revision else { return }
        // Continuous slider movement gets immediate cached geometry. Publish
        // the final native resources after the gesture, without interrupting
        // a press/release animation or doing PNG work on its event callback.
        guard !machine.buttonDown, machine.motion == .normal || machine.motion == .idle else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.commitSizes(resources, generation: generation, revision: revision)
            }; return
        }
        let seedBefore = GLCursorBridge.cursorSeed()
        let continueCurrentRole = roleID != nil && (renderer.owns(seed: seedBefore) || seedBefore == lastSeed)
        let updated = normal.merging(resources.0, uniquingKeysWith: { _, new in new })
        normalVisualClips.merge(resources.1, uniquingKeysWith: { _, new in new })
        renderer.configureNativeNormals(updated, visualClips: normalVisualClips, smoothEdges: theme?.appearance.effectiveSmoothEdges ?? true,
            independentRoles: theme?.mapping?.detailedNativeRoles == true)
        for id in resources.0.keys.sorted() {
            let code = GLCursorBridge.updateCursor(resources.0[id]!, identifier: id, refresh: false)
            guard code == 0 else { fail(ThemeError.invalid(L("更新光标大小失败：\(id)，错误 \(code)。"))); return }
        }
        normal = updated; registeredScales.merge(resources.2, uniquingKeysWith: { _, new in new })
        recognition?.updateRegistered(updated)
        dirtyRegistrationIDs.subtract(resources.0.keys)
        pendingRegistration = nil; registeredMatch = false
        // Disabling background updates while registering can expose the
        // foreground application's cached arrow. It is our registration
        // handoff, not a new role selection. Resume the already identified
        // image before the recognizer observes that intermediate picture.
        lastSeed = continueCurrentRole ? GLCursorBridge.cursorSeed() : -1
        if continueCurrentRole { render() } else { updateIdentification() }
        scheduleNext()
    }
    func setShakeEnabled(_ value: Bool) { shakeEnabled = value; shake.reset(); render(); scheduleNext() }
    #if GALLERY_RUNTIME_CHECKS
    var testPhysicalDown: Bool?
    var testPointerLocation: CGPoint?
    /// Exercise input scheduling with no registered/prepared cursor resources.
    /// render() can only pass through; the normal user's runtime stays intact.
    func testBeginUnregistered(_ theme: GalleryTheme) {
        precondition(!enabled && originals.isEmpty)
        self.theme = theme; roles = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, $0) })
        canonicalRoles = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, $0.id) })
        roleID = theme.roles[0].id; machine.selectRole(roleID, now: now)
        lastSeed = GLCursorBridge.cursorSeed(); testPhysicalDown = false; testRecognitionSuspended = true; enabled = true
        lastLeftEdge = -Double.infinity; lastLeftDown = 0; lastLeftUp = 0
        testPointerLocation = NSEvent.mouseLocation
        lastLocation = pointerLocation; lastScroll = counter(.scrollWheel); lastWatchdog = now
        inputCounters = MouseCounterLedger(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp))
        scenes.testOverride = false
        scenes.onChange = { [weak self] active in self?.sceneChanged(active) }
        scenes.onActivity = { [weak self] in self?.sceneActivity() }
    }
    func testPrepareUnselectedPlayback() throws {
        precondition(enabled && originals.isEmpty)
        renderer.testUnselectedLoops = true
        prepared = try PreparedCursors(roles: Array(roles.values))
        normal = try roles.compactMapValues { role in
            try role.clip(.normal).map { try CursorImages.capeDictionary($0) }
        }
        registeredScales = roles.mapValues { pointerScale * $0.scale }
        renderer.configureNativeNormals(normal)
    }
    func testStartIdle() {
        machine.reset(now: now - idleDelay)
        machine.tick(now: now, idleDelay: idleDelay, idleEnabled: true)
        render(); scheduleNext()
    }
    func testActivateShake() {
        shakeEnabled = true
        let time = now
        for (x, offset) in [(0.0, -0.10), (120, -0.08), (-120, -0.06), (120, -0.04), (-120, -0.02)] {
            shake.observe(x: x, y: 0, at: time + offset)
        }
    }
    func testEndUnregistered() {
        precondition(originals.isEmpty)
        waitOverlay.onChange = nil; waitOverlay.willActivate = nil; waitOverlay.stop(); waitRoleID = nil
        enabled = false; timer.cancel(); cancelConfirmation()
        scenes.onChange = nil; scenes.onActivity = nil; scenes.stop(); scenes.testOverride = nil
        if renderer.testUnselectedLoops {
            renderer.stop(restoring: nil); prepared = nil; normal.removeAll(); registeredScales.removeAll()
        }
        theme = nil; roles.removeAll(); canonicalRoles.removeAll(); roleID = nil; testPhysicalDown = nil; testPointerLocation = nil
    }
    func testAttachWait(_ identifier: String, query: @escaping (pid_t) -> Bool) throws {
        precondition(enabled && originals.isEmpty)
        guard let role = roles[identifier] else { return }
        prepared = try PreparedCursors(roles: [role]); waitRoleID = identifier
        configureWaitCallbacks()
        waitOverlay.testStart(prepared!.clip(role: identifier, motion: .normal)!, query: query)
    }
    func injectObserved(_ type: CGEventType, timestamp: Double? = nil, position: CGPoint? = nil) { handle(type, timestamp: timestamp, position: position) }
    var renderedFrame: Data? { renderer.displayedFrame }
    var testMotion: Motion { machine.motion }
    var testMotionStartedAt: Double { machine.motionStartedAt }
    var observationDescription: String { observation.description }
    var testMissionControl: Bool { scenes.missionControl }
    func testRegisteredShellImage(at directory: URL) throws -> Bool {
        let id = "com.apple.coregraphics.Arrow"
        guard let clip = roles[id]?.clip(.normal), let prepared = prepared?.clip(role: id, motion: .normal) else { return false }
        renderer.present(prepared, role: id, motion: .normal, scale: 1, started: now, now: now, staticOnly: true)
        guard let snapshot = GLCursorBridge.currentSnapshot() else { return false }
        try CursorImages.png(snapshot.image).write(to: directory.appendingPathComponent("shell-actual.png"))
        var matcher = CursorMatcher(); matcher.add(clip, role: id, applied: true)
        return matcher.identify(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
                                hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y).appliedRoles.contains(id)
    }
    var testRecognitionSuspended = false
    func testIdentify(_ ids: [String], applied: [String] = []) {
        lastSeed = GLCursorBridge.cursorSeed(); applyIdentification(CursorIdentification(roles: ids, appliedRoles: applied))
    }
    var testFrameDeadline: Double? { renderer.nextFrameDeadline }
    var testSubmissions: Int { renderer.submissions }
    func testDeliverObservation(seed: Int32, roles ids: [String]) {
        acceptObservation(seed: seed, found: CursorIdentification(roles: ids), generation: generation, revision: roleRevision)
    }
    var testRole: String? { roleID }
    var testThemeName: String? { theme?.name }
    var testEffectiveIdleDelay: Double { idleDelay }
    func testScene(_ value: Bool?) { scenes.testOverride = value; scenes.check(force: true) }
    func testSceneNotice(_ type: Int32) { scenes.testNotice(type) }
    func testSceneTick() { tick() }
    func testRoleScale(_ id: String) -> Double? { roles[id]?.scale }
    var testStats: [String: Any] {
        ["status": status, "enabled": enabled, "motion": machine.motion.rawValue, "motionStart": machine.motionStartedAt,
         "source": observation.description, "sourceEvents": observation.deliveredEvents, "ticks": tickCount,
         "renderer": "system", "submissions": renderer.submissions, "registeredRoles": normal.keys.sorted(), "nativeVisible": GLCursorBridge.cursorVisibility(), "missionControl": scenes.missionControl,
         "inputs": inputRecords, "rawInputs": rawInputRecords, "renders": renderRecords, "frames": renderer.frameRecords, "observations": observationRecords,
         "seed": GLCursorBridge.cursorSeed(), "lastSeed": lastSeed, "ownsCurrent": renderer.owns(seed: GLCursorBridge.cursorSeed())]
    }
    #endif
    private var journalURL: URL {
        recoveryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery/recovery.plist")
    }
    var hasRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    var diagnostics: String { GLCursorBridge.diagnostics() + " · " + observation.description }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var pointerLocation: CGPoint {
        #if GALLERY_RUNTIME_CHECKS
        if let testPointerLocation { return testPointerLocation }
        #endif
        return NSEvent.mouseLocation
    }
    private func roleFamily(_ id: String) -> String { theme?.roleFamily(id) ?? CursorCatalog.family(id) }
    private var currentRole: CursorRole? { roleID.flatMap { roles[$0] } }
    private var idleDelay: Double { currentRole?.idleDelay(default: theme?.idleDelay ?? 8) ?? theme?.idleDelay ?? 8 }
    func setRoleIdleDelay(_ value: Double?, for identifier: String) {
        guard value == nil || (value!.isFinite && (1...600).contains(value!)) else { return }
        let family = roleFamily(identifier)
        for id in roles.keys where roleFamily(id) == family { roles[id]?.idleDelayOverride = value }
        scheduleNext()
    }
    private func counter(_ type: CGEventType) -> UInt32 {
        #if GALLERY_RUNTIME_CHECKS
        if testPointerLocation != nil, type == .scrollWheel { return 0 }
        #endif
        return CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
    }

    func start(_ input: GalleryTheme) {
        guard !enabled else { return }
        var theme = input
        for (source, target) in CursorCatalog.compatibilityAliases {
            if !theme.roles.contains(where: { $0.id == target }), var role = theme.roles.first(where: { $0.id == source }) {
                role.id = target; theme.roles.append(role)
            }
        }
        do {
            try theme.validate()
            if !ownsSession, let acquireSession { try acquireSession(); ownsSession = true }
            let sourceRoles = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, $0) })
            var appearance = CursorAppearanceRenderer(theme.appearance)
            for index in theme.roles.indices where !theme.roles[index].usesNative {
                theme.roles[index].clips = try theme.roles[index].clips.mapValues { try appearance.render($0) }
            }
            pointerScale = theme.pointerScale
            guard GLCursorBridge.available() else { throw ThemeError.invalid(L("此系统未提供所需光标接口。编辑器仍可使用。")) }
            guard !hasRecovery else { throw ThemeError.invalid(L("存在上次未完成的恢复记录。请先恢复上次光标。")) }
            var backup: [String: [String: Any]] = [:], base: [String: [String: Any]] = [:]
            var visualClips: [String: CursorClip] = [:]
            var unsupported: [String: String] = [:]
            var waitOriginal: [String: Any]?
            let busyRole = theme.roles.first { NativeCursorCatalog.identity($0.id) == "com.apple.coregraphics.Wait" && !$0.usesNative }
            var matcher = CursorMatcher()
            for role in theme.roles where !CursorCatalog.assetOnly(role.id) {
                if NativeCursorCatalog.identity(role.id) == CursorRestoreJournal.waitID {
                    guard nativeWait, !role.usesNative, role.id == busyRole?.id else { continue }
                    // Save every original representation before publishing anything.
                    // Only this role opts into approximate <=24-frame restoration.
                    guard let raw = GLCursorBridge.readCursor(CursorRestoreJournal.waitID),
                          let restore = try? CursorResourceSampling.sampled(raw),
                          GLCursorBridge.prepareCursor(restore) != nil else {
                        unsupported[CursorRestoreJournal.waitID] = L("无法取得可恢复的系统资源，保留原生光标。")
                        continue
                    }
                    let clip = role.clip(.normal)!.scaled(by: pointerScale * role.scale).alignedToPixels().sampled()
                    let dictionary = try CursorImages.capeDictionary(clip, smoothEdges: theme.appearance.effectiveSmoothEdges)
                    guard GLCursorBridge.prepareCursor(dictionary) != nil else { continue }
                    waitOriginal = raw; backup[CursorRestoreJournal.waitID] = restore
                    base[CursorRestoreJournal.waitID] = dictionary; visualClips[CursorRestoreJournal.waitID] = clip
                    matcher.addRepresentations(raw, role: role.id)
                    matcher.addRepresentations(dictionary, role: role.id, applied: true)
                    continue
                }
                if let standard = GLCursorBridge.standardCursor(role.id) { matcher.addRepresentations(standard, role: role.id) }
                guard let old = GLCursorBridge.readCursor(role.id), let restored = try? CursorImages.fromCape(old) else {
                    if !role.usesNative { unsupported[NativeCursorCatalog.identity(role.id)] = L("无法取得可恢复的系统资源，保留原生光标。") }
                    continue
                }
                guard restored.frames.count <= 24 else {
                    if !role.usesNative { unsupported[NativeCursorCatalog.identity(role.id)] = L("系统原始动画超过当前接口可安全恢复的帧数，保留原生光标。") }
                    continue
                }
                matcher.addRepresentations(old, role: role.id)
                backup[role.id] = old
                if !role.usesNative {
                    var clip = role.clip(.normal)!.scaled(by: pointerScale * role.scale).alignedToPixels()
                    visualClips[role.id] = clip
                    // Foreground apps reselect IBeam on every cursor-region
                    // update. An animated registered resource restarts then;
                    // Gallery owns the continuous clock and cached frame loop.
                    if clip.frames.count > 1 && !CursorCatalog.isResize(role.id) && NativeCursorCatalog.identity(role.id) != CursorRestoreJournal.waitID { clip.frames = [clip.frames[0]] }
                    base[role.id] = try CursorImages.capeDictionary(clip, smoothEdges: theme.appearance.effectiveSmoothEdges)
                    matcher.add(role.clip(.normal)!, role: role.id, applied: true)
                    if theme.appearance.shadow, let source = sourceRoles[role.id]?.clip(.normal) {
                        matcher.add(source, role: role.id, applied: false)
                    }
                }
            }
            let supported = Set(base.keys.map(NativeCursorCatalog.identity))
            unsupportedRoles = unsupported.filter { !supported.contains($0.key) }
            guard !base.isEmpty || busyRole != nil || theme.roles.contains(where: \.usesNative) else { throw ThemeError.invalid(L("未能备份对应系统光标，未进行替换。")) }
            prepared = try PreparedCursors(roles: theme.roles.filter { base[$0.id] != nil || $0.id == busyRole?.id })
            if base.isEmpty { backup.removeAll() }
            if !backup.isEmpty {
                let data = try CursorRestoreJournal.encode(cursors: backup, originalWait: waitOriginal)
                try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: journalURL, options: .atomic)
            }
            originals = backup; originalWait = waitOriginal; nativeWaitActive = waitOriginal != nil
            normal = base; self.theme = theme
            normalVisualClips = visualClips; dirtyRegistrationIDs.removeAll()
            roles = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, $0) })
            registeredScales = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, pointerScale * $0.scale) })
            canonicalRoles = Dictionary(uniqueKeysWithValues: theme.roles.map { role in
                let family = theme.roles.filter { theme.roleFamily($0.id) == theme.roleFamily(role.id) }
                // A named system alias may be unavailable on a particular OS.
                // Resolve to an entry we actually backed up/prepared, instead
                // of silencing the entire family because its first ID failed.
                return (role.id, family.first(where: { base[$0.id] != nil || $0.usesNative })?.id ?? role.id)
            })
            renderer.configureNativeNormals(base, visualClips: visualClips, smoothEdges: theme.appearance.effectiveSmoothEdges, independentRoles: theme.mapping?.detailedNativeRoles == true)
            if let arrow = theme.roles.first(where: { CursorCatalog.isArrow($0.id) }) {
                for motion in [Motion.release, .hold] {
                    if let clip = prepared?.clip(role: arrow.id, motion: motion) {
                        renderer.warmInteraction(clip, role: arrow.id, motion: motion, scale: pointerScale * arrow.scale)
                    }
                }
            }
            if let text = theme.roles.first(where: { CursorCatalog.family($0.id) == "com.apple.coregraphics.IBeam" && base[$0.id] != nil }),
               let clip = prepared?.clip(role: text.id, motion: .normal), clip.frames.count > 1 {
                renderer.warmInteraction(clip, role: text.id, motion: .normal, scale: pointerScale * text.scale, limit: 96)
            }
            // Prime distinct click frames, including text. Repeated copies
            // of the same image must not consume the entire warm-up budget.
            var warmed = Set<String>()
            for role in theme.roles where base[role.id] != nil && warmed.insert(theme.roleFamily(role.id)).inserted {
                if let clip = prepared?.clip(role: role.id, motion: .press) {
                    renderer.warmInteraction(clip, role: role.id, motion: .press, scale: pointerScale * role.scale, limit: 4)
                }
                for motion in [Motion.release, .hold] {
                    if let clip = prepared?.clip(role: role.id, motion: motion) {
                        renderer.warmInteraction(clip, role: role.id, motion: motion, scale: pointerScale * role.scale, limit: 1)
                    }
                }
            }
            recognition = CursorRecognition(matcher: matcher, registered: base); generation += 1
            if !base.isEmpty { _ = GLCursorBridge.clearCoreCursorCache() }
            for id in base.keys.sorted() {
                let code = GLCursorBridge.updateCursor(base[id]!, identifier: id, refresh: false)
                guard code == 0 else { throw ThemeError.invalid(L("光标注册失败：\(id)，错误 \(code)。")) }
                if id == CursorRestoreJournal.waitID {
                    guard let current = GLCursorBridge.readCursor(id), CursorResourceSampling.equal(base[id]!, current) else {
                        throw ThemeError.invalid(L("等待光标注册校验失败，已尝试恢复启用前的资源。"))
                    }
                }
            }
            enabled = true; machine.reset(now: now); normalClocks.reset(); suspended = false; locked = false; wasPaused = false
            excluded = theme.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            inputCounters = MouseCounterLedger(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp)); counterGesture = false
            lastLocation = NSEvent.mouseLocation; lastScroll = counter(.scrollWheel); lastSeed = -1
            observation.onEvent = { [weak self] type in
                guard let self else { return }
                self.waitOverlay.pointerChanged(window: self.observation.latestWindowID)
                self.scenes.resolveDockWindow(self.observation.latestWindowID)
                self.handle(type, timestamp: self.observation.latestTimestamp, position: self.observation.latestPosition, observed: true)
            }
            observation.start(); installSessionObservers()
            if !nativeWait, let busyRole, let clip = prepared?.clip(role: busyRole.id, motion: .normal) {
                waitRoleID = busyRole.id
                configureWaitCallbacks()
                if !waitOverlay.start(clip, scale: pointerScale * busyRole.scale, smooth: theme.appearance.effectiveSmoothEdges) {
                    unsupportedRoles["com.apple.coregraphics.Wait"] = L("无法观察系统等待状态，保留原生等待光标。")
                    waitRoleID = nil
                }
                waitOverlay.setSuspended(paused)
            }
            scenes.start()
            scenes.onChange = { [weak self] active in self?.sceneChanged(active) }
            scenes.onActivity = { [weak self] in self?.sceneActivity() }
            scenes.check(force: true)
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: L("保持交互光标响应"))
            lastLeftEdge = -Double.infinity; lastLeftDown = 0; lastLeftUp = 0; lastWatchdog = now
            lastCornerCheck = 0; tickCount = 0; unknownSince = nil
            statusKey = nil
            status = L("已启用 · 关闭窗口后继续运行"); updateIdentification(); armTimer(after: 0.008)
        } catch {
            let message = error.localizedDescription
            if !originals.isEmpty { _ = stop() }
            else { endSession() }
            self.error = message
        }
    }
    @discardableResult
    func stop() -> Bool {
        waitOverlay.onChange = nil; waitOverlay.willActivate = nil; waitOverlay.stop(); waitRoleID = nil
        pendingRegistration?.cancel(); pendingRegistration = nil; registrationRevision += 1
        timer.cancel(); cancelConfirmation(); observation.stop(); scenes.onChange = nil; scenes.onActivity = nil; scenes.stop(); generation += 1; recognizing = false; recognition = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; distributedObservers.removeAll()
        enabled = false
        statusKey = nil
        var failures: [String] = []
        renderer.stop(restoring: roleID.flatMap { originals[$0] })
        if !originals.isEmpty { _ = GLCursorBridge.clearCoreCursorCache() }
        for id in originals.keys.sorted() {
            let code = GLCursorBridge.updateCursor(originals[id]!, identifier: id, refresh: false)
            if code != 0 { failures.append(id) }
            else if id == CursorRestoreJournal.waitID {
                if let current = GLCursorBridge.readCursor(id), CursorResourceSampling.equal(originals[id]!, current) {} else { failures.append(id) }
            }
        }
        // Read after all aliases have been restored: an alias update can
        // replace the canonical slot after its individual write returned zero.
        if !originals.isEmpty {
            _ = GLCursorBridge.clearCoreCursorCache()
            for id in originals.keys.sorted() {
                guard let current = GLCursorBridge.readCursor(id), CursorResourceSampling.equal(originals[id]!, current) else {
                    if !failures.contains(id) { failures.append(id) }; continue
                }
            }
            // Refresh the visible image as well as the resource bank. With no
            // active background ownership, successful registration alone can
            // leave the foreground app's last theme frame on screen.
            if let arrow = originals["com.apple.coregraphics.Arrow"], failures.isEmpty {
                _ = GLCursorBridge.setBackgroundCursorUpdates(true)
                if GLCursorBridge.updateCursor(arrow, identifier: "com.apple.coregraphics.Arrow", refresh: true) != 0 {
                    failures.append("com.apple.coregraphics.Arrow")
                }
            }
        }
        GLCursorBridge.setDockCursorOverride(false); _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        if failures.isEmpty {
            if let originalWait {
                let archiveURL = journalURL.deletingPathExtension().appendingPathExtension("wait-original.plist")
                let saved = (try? Data(contentsOf: archiveURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let oldCount = ((saved?["Resource"] as? [String: Any])?["FrameCount"] as? NSNumber)?.intValue ?? 0
                let system = ProcessInfo.processInfo.operatingSystemVersionString
                if saved?["System"] as? String != system || oldCount < ((originalWait["FrameCount"] as? NSNumber)?.intValue ?? 0) {
                    if let data = try? PropertyListSerialization.data(fromPropertyList: ["System": system, "Resource": originalWait], format: .binary, options: 0) {
                        try? data.write(to: archiveURL, options: .atomic)
                    }
                }
            }
            if !originals.isEmpty { try? FileManager.default.removeItem(at: journalURL) }
            originals.removeAll(); originalWait = nil; status = L("已停用 · 已恢复启用前的光标")
            endSession()
        } else { error = L("部分光标恢复失败，恢复记录已保留。请再次恢复，必要时注销登录。"); status = L("需要恢复光标") }
        roleAliases.removeAll(); roles.removeAll(); canonicalRoles.removeAll(); normal.removeAll(); prepared = nil
        normalVisualClips.removeAll(); dirtyRegistrationIDs.removeAll()
        roleID = nil; theme = nil; nativeWaitActive = false; registeredMatch = false; registeredScales.removeAll(); shake.reset()
        machine.reset(now: now); lastProbe = 0; lastSeed = -1; dockGesture = false
        return failures.isEmpty
    }
    func recover() {
        guard !enabled else { _ = stop(); return }
        do {
            if !ownsSession, let acquireSession { try acquireSession(); ownsSession = true }
            let backup = try CursorRestoreJournal.decode(Data(contentsOf: journalURL))
            originals = backup.cursors; originalWait = backup.originalWait; _ = stop()
        } catch { if originals.isEmpty { endSession() }; self.error = error.localizedDescription }
    }
    private func endSession() {
        if ownsSession { ownsSession = false; releaseSession?() }
    }
    func requestInputAccess() {
        _ = CGRequestListenEventAccess()
        if enabled { observation.start(); armTimer(after: 0.008) }
    }
    private func updateIdentification() {
        #if GALLERY_RUNTIME_CHECKS
        if testRecognitionSuspended && !renderer.needsConfirmation { return }
        #endif
        if editorCorner.active || waitOverlay.active { return }
        let seed = GLCursorBridge.cursorSeed()
        if scenes.missionControl {
            let arrow = "com.apple.coregraphics.Arrow"
            if roles[arrow] != nil, roleID != canonicalRoles[arrow] {
                applyIdentification(CursorIdentification(roles: [arrow]))
            }
            return
        }
        if !renderer.needsConfirmation, !renderer.owns(seed: seed), let role = renderer.knownRole(seed: seed), roles[role] != nil {
            lastSeed = seed
            applyIdentification(CursorIdentification(roles: [role])); return
        }
        guard !recognizing, let recognition, !renderer.owns(seed: seed) || renderer.needsConfirmation else { return }
        guard seed != lastSeed || renderer.needsConfirmation || now - lastProbe > 1 else { return }
        confirmation.synchronize(revision: renderer.needsConfirmation ? renderer.imageRevision : nil, now: now)
        if renderer.needsConfirmation {
            guard confirmation.shouldProbe(seed: seed, now: now) else { return }
            confirmation.beginProbe(seed: seed)
        }
        lastProbe = now; recognizing = true
        confirmationTimer.cancel(); confirmationDue = nil
        let currentGeneration = generation
        let currentRoleRevision = roleRevision
        let pending = renderer.pendingImage
        let referenceRevision = renderer.imageRevision
        let recoveryStarted = machine.motionStartedAt
        #if GALLERY_RUNTIME_CHECKS
        let probeStarted = now
        #endif
        var recovery = renderer.nativeRecoveryImages
        recovery?.releasing = machine.motion == .release
        recognition.probe(pendingImage: pending?.fingerprint, nativeImages: renderer.nativeGuardFingerprints, nativeAnimation: renderer.nativeAnimationImages,
                          nativeRecovery: recovery) { [weak self] seed, found, ownImage, recoveryIndex in
            DispatchQueue.main.async {
                guard let self, self.enabled, currentGeneration == self.generation else { return }
                self.recognizing = false
                #if GALLERY_RUNTIME_CHECKS
                self.traceTiming("probe", ["latencyMs": (self.now - probeStarted) * 1000, "ownImage": ownImage,
                    "seed": seed, "currentSeed": GLCursorBridge.cursorSeed(), "roles": found?.roles ?? [],
                    "revision": referenceRevision, "currentRevision": self.renderer.imageRevision])
                #endif
                self.confirmation.finishProbe(revision: referenceRevision, now: self.now)
                defer { self.scheduleConfirmation() }
                guard !self.scenes.missionControl else { return }
                if ownImage {
                    guard currentRoleRevision == self.roleRevision,
                          seed == GLCursorBridge.cursorSeed() else { self.retryIdentification(); return }
                    if self.renderer.confirmDisplayed(seed: seed, revision: referenceRevision) {
                        self.cancelConfirmation()
                        // A press/up may have arrived while that image was in
                        // flight. Present the latest phase immediately on ack.
                        self.render(); self.scheduleNext()
                    } else { self.retryIdentification() }
                    return
                }
                self.acceptObservation(seed: seed, found: found, generation: currentGeneration, revision: currentRoleRevision,
                    recoveryIndex: recoveryIndex, recoveryStarted: recoveryStarted)
            }
        }
    }
    private func acceptObservation(seed: Int32, found: CursorIdentification?, generation capturedGeneration: Int, revision: Int,
                                   recoveryIndex: Int? = nil, recoveryStarted: Double? = nil) {
        #if GALLERY_RUNTIME_CHECKS
        observationRecords.append(["seed": seed, "current": GLCursorBridge.cursorSeed(), "roles": found?.roles ?? [],
            "revision": revision, "currentRevision": roleRevision, "role": roleID ?? "nil", "at": now,
            "ownsSnapshot": renderer.owns(seed: seed), "ownsCurrent": renderer.owns(seed: GLCursorBridge.cursorSeed())])
        if observationRecords.count > 100 { observationRecords.removeFirst() }
        #endif
        guard enabled, capturedGeneration == generation, !waitOverlay.active else { return }
        recognizing = false
        guard !scenes.missionControl else { return }
        #if GALLERY_RUNTIME_CHECKS
        if testRecognitionSuspended { return }
        #endif
        guard revision == roleRevision else { retryIdentification(); return }
        // The captured image must still be the visible resource. Our current
        // frame does not make an older foreign observation valid again.
        guard !renderer.owns(seed: seed) else { return }
        guard let found, seed == GLCursorBridge.cursorSeed() else { retryIdentification(); return }
        if let index = recoveryIndex, machine.motion == .release, recoveryStarted == machine.motionStartedAt,
           let role = currentRole, let clip = role.clip(.release) {
            // A foreground cache may already have shown a later release frame.
            // Continue from it rather than visibly expanding back to frame 0.
            renderer.adoptReleaseFrame(index, role: role.id, started: machine.motionStartedAt, now: now, clip: clip)
        }
        renderer.cancelPending()
        lastSeed = seed; applyIdentification(found)
    }
    private func applyIdentification(_ found: CursorIdentification) {
        let ids: [String]
        if scenes.missionControl, roles["com.apple.coregraphics.Arrow"] != nil {
            ids = ["com.apple.coregraphics.Arrow"]
        } else { ids = found.roles.filter { roles[$0] != nil } }
        let candidates = Set(ids.compactMap { canonicalRoles[$0] })
        let selected = roleID.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.sorted().first
        registeredMatch = selected != nil && found.appliedRoles.contains { canonicalRoles[$0] == selected }

        if selected == nil, roleID != nil {
            if unknownSince == nil { unknownSince = now; lastSeed = -1; armTimer(after: 0.025); return }
            if now - unknownSince! < 0.025 { lastSeed = -1; armTimer(after: 0.025); return }
        } else { unknownSince = nil }
        // Alias-only changes must never restart a click or jump to hold.
        roleAliases = ids
        if selected != roleID {
            renderer.cancelInteractionWarmup()
            roleRevision += 1
            roleID = selected
            machine.selectRole(selected, now: now)
            if selected == nil {
                renderer.passThrough()
                statusKey = nil
                status = L("自定义光标 · 等待已知状态后自动恢复")
            }
        }
        reconcileRelease(); render(); scheduleNext()
    }
    private func sceneChanged(_ active: Bool) {
        guard enabled else { return }
        #if GALLERY_RUNTIME_CHECKS
        traceTiming("sceneChanged", ["active": active, "role": roleID ?? "nil", "motion": machine.motion.rawValue])
        #endif
        waitOverlay.setSuspended(active || paused)
        lastSeed = -1; registeredMatch = false
        sceneActivity()
        if active {
            applyIdentification(CursorIdentification(roles: ["com.apple.coregraphics.Arrow"]))
        }
        tick()
    }
    private func sceneActivity() {
        guard enabled else { return }
        let wasIdle = machine.motion == .idle
        let seed = GLCursorBridge.cursorSeed()
        let known = renderer.owns(seed: seed) || roleID.map { renderer.knownRole(seed: seed) == $0 } == true || seed == lastSeed
        machine.activity(now: now)
        roleRevision += 1
        if wasIdle {
            cancelConfirmation(); renderer.passThrough()
            registeredMatch = false; lastSeed = known ? seed : -1
            if known || scenes.missionControl { render() } else { updateIdentification() }
        }
        scheduleNext()
    }
    private func clearTemporary() {
        cancelConfirmation(); renderer.cancelInteractionWarmup(); renderer.passThrough(); shake.reset(); normalClocks.reset()
    }
    private func updateWaitScale() {
        if let id = waitRoleID, let role = roles[id] { waitOverlay.setScale(pointerScale * role.scale) }
    }
    private func configureWaitCallbacks() {
        waitOverlay.willActivate = { [weak self] in self?.cancelConfirmation(); self?.renderer.passThrough() }
        waitOverlay.onChange = { [weak self] active in self?.waitOverlayChanged(active) }
    }
    private func waitOverlayChanged(_ active: Bool) {
        guard enabled else { return }
        cancelConfirmation(); registeredMatch = false; lastSeed = -1
        if active, let waitRoleID {
            applyIdentification(CursorIdentification(roles: [waitRoleID]))
        } else {
            // A release from the busy role must not carry into the ordinary
            // role when the pointer leaves or the foreground app recovers.
            roleRevision += 1; roleID = nil; roleAliases.removeAll(); unknownSince = nil
            machine.selectRole(nil, now: now); statusKey = nil
            updateIdentification(); armTimer(after: 0.001)
        }
    }
    private var paused: Bool { suspended || locked || excluded }
    private func physicalLeftDown() -> Bool {
        #if GALLERY_RUNTIME_CHECKS
        if let testPhysicalDown { return testPhysicalDown }
        #endif
        return CGEventSource.buttonState(.combinedSessionState, button: .left)
    }
    private func eventTime(_ type: CGEventType) -> Double {
        let age = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
        return age.isFinite && age >= 0 && age < 60 ? now - age : now
    }
    private func reconcileRelease() {
        guard machine.buttonDown, !physicalLeftDown() else { return }
        let up = eventTime(.leftMouseUp)
        guard up >= lastLeftDown || now - lastLeftDown >= 0.008 else { return }
        let timestamp = max(lastLeftDown, up >= lastLeftDown ? up : now)
        #if GALLERY_RUNTIME_CHECKS
        rawInputRecords.append(["edge": "reconcile-up", "at": now, "eventAt": timestamp,
            "role": roleID ?? "nil", "motion": machine.motion.rawValue, "start": machine.motionStartedAt,
            "hid": CGEventSource.buttonState(.hidSystemState, button: .left), "combined": CGEventSource.buttonState(.combinedSessionState, button: .left)])
        if rawInputRecords.count > 300 { rawInputRecords.removeFirst() }
        #endif
        lastLeftUp = timestamp; lastLeftEdge = max(lastLeftEdge, timestamp)
        confirmation.reset()
        machine.up(now: timestamp, enabled: theme?.clickEnabled ?? false)
        acknowledgeCounter(.up); counterGesture = false
    }
    private func acknowledgeCounter(_ edge: MouseEdge) {
        #if GALLERY_RUNTIME_CHECKS
        if testPhysicalDown != nil { return }
        #endif
        inputCounters.acknowledge(edge)
    }
    private func pollInput() {
        let downs = counter(.leftMouseDown), ups = counter(.leftMouseUp)
        #if GALLERY_RUNTIME_CHECKS
        if testPhysicalDown != nil { inputCounters = MouseCounterLedger(downs: downs, ups: ups); return }
        #endif
        let edges = inputCounters.poll(downs: downs, ups: ups, isDown: physicalLeftDown())
        var accepted = false
        for edge in edges {
            let type: CGEventType = edge == .down ? .leftMouseDown : .leftMouseUp
            accepted = handle(type, timestamp: eventTime(type), renderAfter: false) || accepted
        }
        if accepted && observation.active { counterGesture = machine.buttonDown }
    }
    private func armTimer(after delay: Double) {
        guard enabled else { return }
        let armedAt = now
        let precise = renderer.nextFrameDeadline != nil || machine.transitionDeadline != nil
            || (shakeEnabled && shake.nextDeadline(at: armedAt) != nil)
        let created = timer.arm(at: armedAt + max(0.001, delay), precise: precise) { [weak self] expected in
            #if GALLERY_RUNTIME_CHECKS
            if let self { self.traceTiming("timer", ["latenessMs": max(0, (self.now - expected) * 1000),
                "requestedDelayMs": (expected - armedAt) * 1000, "expected": expected, "strict": precise,
                "workerAt": self.timer.testSignalAt, "mode": CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"]) }
            #endif
            self?.tick()
        }
        #if GALLERY_RUNTIME_CHECKS
        if created { testTimerCreations += 1 }
        #else
        _ = created
        #endif
    }
    private func scheduleNext() {
        guard enabled else { return }
        let delay = PointerSchedule.delay(now: now,
            polling: !observation.active || counterGesture, paused: paused,
            frameDeadline: [renderer.nextFrameDeadline, shakeEnabled ? shake.nextDeadline(at: now) : nil].compactMap { $0 }.min(), transitionDeadline: machine.transitionDeadline,
            idleDeadline: (!scenes.missionControl && theme?.idleEnabled == true && currentRole?.clip(.idle) != nil && !machine.buttonDown && machine.motion == .normal)
                ? machine.lastActivity + idleDelay : nil)
        armTimer(after: delay)
        scheduleConfirmation()
    }
    private func cancelConfirmation() {
        confirmationTimer.cancel(); confirmationDue = nil; confirmation.reset()
    }
    private func retryIdentification() {
        if renderer.needsConfirmation { scheduleConfirmation() } else { armTimer(after: 0.001) }
    }
    private func scheduleConfirmation() {
        guard enabled, !paused, !scenes.missionControl, !editorCorner.active, renderer.needsConfirmation else {
            cancelConfirmation(); return
        }
        confirmation.synchronize(revision: renderer.imageRevision, now: now)
        // The worker completion will schedule the next check. A timer must not
        // poll an already running capture or wake the full rendering pipeline.
        guard !recognizing, let due = confirmation.deadline else {
            confirmationTimer.cancel(); confirmationDue = nil; return
        }
        if confirmationTimer.deadline != nil, confirmationDue == due { return }
        confirmationTimer.cancel(); confirmationDue = due
        confirmationTimer.arm(at: due, precise: true) { [weak self] _ in
            guard let self else { return }
            self.confirmationDue = nil
            let held = self.machine.buttonDown
            self.reconcileRelease()
            if held && !self.machine.buttonDown { self.render(); self.scheduleNext() }
            self.updateIdentification(); self.scheduleConfirmation()
        }
    }
    private func tick() {
        guard enabled, let theme else { return }; tickCount += 1
        #if GALLERY_RUNTIME_CHECKS
        traceTiming("tickBegin", ["role": roleID ?? "nil", "motion": machine.motion.rawValue, "paused": paused,
            "scene": scenes.missionControl])
        #endif
        if paused {
            if !wasPaused { clearTemporary(); machine.reset(now: now); wasPaused = true }
            scheduleNext(); return
        }
        if wasPaused { wasPaused = false; lastSeed = -1; inputCounters = MouseCounterLedger(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp)); counterGesture = false }
        if !observation.active || counterGesture || now - lastWatchdog >= 0.19 {
            lastWatchdog = now; pollInput(); scenes.check()
        }
        let location = pointerLocation
        if location != lastLocation {
            machine.activity(now: now); lastLocation = location
            if shakeEnabled { shake.observe(x: location.x, y: location.y, at: now) }
        }
        synchronizeEditorCorner(at: location)
        if now - lastScrollCheck > 0.19 {
            lastScrollCheck = now
            let scroll = counter(.scrollWheel)
            if scroll != lastScroll { machine.activity(now: now); lastScroll = scroll }
        }
        #if GALLERY_RUNTIME_CHECKS
        traceTiming("tickInput", ["role": roleID ?? "nil", "motion": machine.motion.rawValue, "scene": scenes.missionControl])
        #endif
        reconcileRelease()
        machine.tick(now: now, idleDelay: idleDelay, idleEnabled: theme.idleEnabled && !scenes.missionControl && currentRole?.clip(.idle) != nil)
        updateIdentification(); render(); scheduleNext()
    }
    private func render() {
        #if GALLERY_RUNTIME_CHECKS
        testRenderCalls += 1
        #endif
        guard enabled, !paused, let role = currentRole else { return }
        reconcileRelease()
        if nativeWaitActive, NativeCursorCatalog.identity(role.id) == CursorRestoreJournal.waitID {
            renderer.passThrough(); updateStatus(role: role, motion: .normal, native: false); return
        }
        if waitOverlay.active, role.id == waitRoleID {
            let motion = role.clip(machine.motion) == nil ? .normal : machine.motion
            guard let clip = prepared?.clip(role: role.id, motion: motion) else { return }
            let started = motion == .normal ? normalClocks.start(for: roleFamily(role.id), suggested: machine.motionStartedAt, now: now) : machine.motionStartedAt
            waitOverlay.present(clip, motion: motion, scale: pointerScale * role.scale * (shakeEnabled ? shake.scale(at: now) : 1),
                smooth: theme?.appearance.effectiveSmoothEdges ?? true, started: started)
            updateStatus(role: role, motion: motion, native: false)
            return
        }
        let currentSeed = GLCursorBridge.cursorSeed()
        #if GALLERY_RUNTIME_CHECKS
        traceTiming("render", ["role": role.id, "motion": machine.motion.rawValue,
            "scene": scenes.missionControl, "visible": GLCursorBridge.cursorVisibility(),
            "blocked": !scenes.missionControl && currentSeed != lastSeed && !renderer.owns(seed: currentSeed),
            "seed": currentSeed, "lastSeed": lastSeed, "confirming": renderer.needsConfirmation,
            "recognizing": recognizing, "frameDue": renderer.nextFrameDeadline ?? -1,
            "submissions": renderer.submissions])
        #endif
        // Never overwrite an as-yet unrecognized foreground cursor with the
        // previous role. Our own submitted animation seeds are never matched.
        guard scenes.missionControl || currentSeed == lastSeed || renderer.owns(seed: currentSeed) else { return }
        if role.usesNative || normal[role.id] == nil {
            renderer.passThrough(); updateStatus(role: role, motion: .normal, native: true); return
        }
        let interacting = [.press, .hold, .release].contains(machine.motion)
        if !interacting { dockGesture = false }
        let shellClick = (scenes.missionControl || dockGesture) && interacting
        let shellStatic = scenes.missionControl && !shellClick
        let motion: Motion = shellStatic ? .normal : (role.clip(machine.motion) == nil ? .normal : machine.motion)
        let magnification = shakeEnabled ? shake.scale(at: now) : 1
        let scale = pointerScale * role.scale * magnification
        let interactionClips = [Motion.press, .release].compactMap { motion in
            prepared?.clip(role: role.id, motion: motion).map { (motion, $0) }
        }
        if magnification == 1 { renderer.warmInteractions(interactionClips, role: role.id, scale: scale) }
        else { renderer.cancelInteractionWarmup() }
        guard let clip = prepared?.clip(role: role.id, motion: motion) else { return }
        #if GALLERY_RUNTIME_CHECKS
        let phase = role.id + ":" + motion.rawValue + ":" + String(machine.motionStartedAt)
        if phase != lastRecordedPhase {
            lastRecordedPhase = phase
            renderRecords.append(["role": role.id, "phase": motion.rawValue, "at": now, "start": machine.motionStartedAt, "physicalDown": physicalLeftDown()])
            if renderRecords.count > 200 { renderRecords.removeFirst() }
        }
        #endif
        // Registered resize animations belong to the foreground application's
        // cursor tracking, just like static registered pointers. Replacing each
        // frame from the background can outlive a narrow divider and mask its
        // native exit until the application rebuilds its cursor regions.
        let nativeNormal = clip.frames.count == 1 || CursorCatalog.isResize(role.id)
        if registeredMatch && motion == .normal && nativeNormal && magnification == 1
            && abs(scale - (registeredScales[role.id] ?? -1)) < 0.005 && !renderer.owns(seed: currentSeed) {
            let geometry = clip.clip.scaled(by: scale).alignedToPixels()
            renderer.passThrough(frame: clip.frames[0].data, size: CGSize(width: geometry.width, height: geometry.height))
        } else {
            let started = motion == .normal ? normalClocks.start(for: roleFamily(role.id), suggested: machine.motionStartedAt, now: now) : machine.motionStartedAt
            renderer.present(clip, role: role.id, motion: motion, scale: scale, started: started, now: now,
                staticOnly: shellStatic, synchronizeRegistration: magnification == 1 && abs(scale - (registeredScales[role.id] ?? -1)) < 0.005,
                shell: shellClick)
        }
        updateStatus(role: role, motion: motion, native: false, shellClick: shellClick)
    }
    private func updateStatus(role: CursorRole, motion: Motion, native: Bool, shellClick: Bool = false) {
        let key = StatusKey(role: role.id, motion: motion, shell: scenes.missionControl, native: native, shellClick: shellClick)
        guard statusKey != key else { return }
        statusKey = key
        let text: String
        if native { text = L("\(role.localizedName) · 系统原有光标") }
        else if role.id == waitRoleID { text = role.localizedName + " · " + motion.title }
        else if scenes.missionControl { text = L("调度中心 · \(shellClick ? motion.title : L("主题静态光标"))") }
        else { text = L("\(role.localizedName) · \(motion.title) · 系统光标通道") }
        if status != text { status = text }
    }
    private func synchronizeEditorCorner(at point: CGPoint) {
        guard roles["com.apple.cursor.35"] != nil, NSApp.isActive, let window = NSApp.windows.first(where: {
            $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.resizable) && $0.title == "Gallery"
        }) else { editorCorner.reset(); return }
        let wasActive = editorCorner.active
        if editorCorner.update(rightDistance: point.x - window.frame.maxX, bottomDistance: point.y - window.frame.minY),
           roles["com.apple.cursor.35"] != nil {
            lastSeed = GLCursorBridge.cursorSeed()
            if !wasActive { applyIdentification(CursorIdentification(roles: ["com.apple.cursor.35"])) }
        } else if wasActive {
            let seed = GLCursorBridge.cursorSeed()
            if renderer.owns(seed: seed) || seed == lastSeed {
                lastSeed = seed
                applyIdentification(CursorIdentification(roles: ["com.apple.coregraphics.Arrow"]))
            } else { updateIdentification() }
        }
    }
    @discardableResult
    private func handle(_ type: CGEventType, timestamp supplied: Double? = nil, position: CGPoint? = nil, observed: Bool = false, renderAfter: Bool = true) -> Bool {
        guard enabled, !paused, let theme else { return false }
        let timestamp = min(now, supplied ?? now)
        let wasIdle = machine.motion == .idle
        machine.activity(now: timestamp)
        #if GALLERY_RUNTIME_CHECKS
        if wasIdle, machine.motion != .idle {
            traceTiming("idleInputExit", ["type": type.rawValue, "observed": observed,
                "scene": scenes.missionControl, "x": position?.x ?? lastLocation.x, "y": position?.y ?? lastLocation.y])
        }
        #endif
        if wasIdle, machine.motion != .idle, scenes.missionControl { updateIdentification() }
        if let position {
            lastLocation = position
            if shakeEnabled { shake.observe(x: position.x, y: position.y, at: timestamp) }
        }
        switch type {
        case .leftMouseDown, .leftMouseUp:
            #if GALLERY_RUNTIME_CHECKS
            rawInputRecords.append(["edge": type == .leftMouseDown ? "raw-down" : "raw-up", "at": now, "eventAt": timestamp,
                "observed": observed, "role": roleID ?? "nil", "motion": machine.motion.rawValue, "start": machine.motionStartedAt,
                "held": machine.buttonDown, "downCount": counter(.leftMouseDown), "upCount": counter(.leftMouseUp),
                "hid": CGEventSource.buttonState(.hidSystemState, button: .left), "combined": CGEventSource.buttonState(.combinedSessionState, button: .left)])
            if rawInputRecords.count > 300 { rawInputRecords.removeFirst() }
            #endif
            if type == .leftMouseDown {
                // Polling and the event monitor can report the same edge
                // with slightly different clocks. A late down must not start
                // a second release after the physical mouse-up was handled.
                guard !machine.buttonDown, timestamp > lastLeftDown + 0.001, timestamp > lastLeftUp else { return false }
            } else {
                guard machine.buttonDown, timestamp >= lastLeftDown else { return false }
            }
            guard timestamp >= lastLeftEdge else { return false }
            confirmation.reset()
            lastLeftEdge = timestamp; lastLocation = position ?? pointerLocation
            #if GALLERY_RUNTIME_CHECKS
            inputRecords.append(["edge": type == .leftMouseDown ? "down" : "up", "at": now, "eventAt": timestamp, "observed": observed])
            if inputRecords.count > 200 { inputRecords.removeFirst() }
            #endif
            if type == .leftMouseDown {
                lastLeftDown = timestamp
                dockGesture = theme.clickEnabled && observed && scenes.cachedDockWindow(observation.latestWindowID)
                normalClocks.reset()
                machine.down(now: timestamp, pressDuration: currentRole?.clip(.press)?.duration, enabled: theme.clickEnabled,
                    split: currentRole?.splitClickAnimation ?? false, releaseDuration: currentRole?.clip(.release)?.duration)
            } else {
                lastLeftUp = timestamp
                machine.up(now: timestamp, enabled: theme.clickEnabled)
            }
            if observed {
                acknowledgeCounter(type == .leftMouseDown ? .down : .up); counterGesture = false
            }
            // A batch may contain down and up together. Consume the complete
            // batch before physical-state reconciliation credits a later edge.
            if observed || renderAfter { reconcileRelease() }
            machine.tick(now: now, idleDelay: idleDelay, idleEnabled: false)
            if renderAfter {
                // A known displayed cursor can react before launching the
                // asynchronous image probe. Unknown roles still fail render's
                // ownership guard rather than borrowing the previous role.
                render(); updateIdentification(); scheduleNext()
                if type == .leftMouseDown, observed, theme.clickEnabled, !dockGesture {
                    let revision = roleRevision, generation = generation
                    scenes.resolveDockWindow(observation.latestWindowID) { [weak self] dock in
                        guard let self, dock, self.enabled, !self.paused, self.generation == generation,
                              self.roleRevision == revision, self.lastLeftDown == timestamp,
                              [.press, .hold, .release].contains(self.machine.motion) else { return }
                        self.dockGesture = true; self.render(); self.scheduleNext()
                    }
                }
            }
            return true
        default:
            if wasIdle { tick(); return false }
            // Position is managed by macOS. Motion only needs to observe a
            // changed role; it must not create a 120Hz rendering timer.
            updateIdentification()
            if NSApp.isActive && now - lastCornerCheck >= 1.0 / 120 {
                lastCornerCheck = now; synchronizeEditorCorner(at: lastLocation)
            }
            // Keep every input sample for recognition and shake detection;
            // image changes follow the existing display cadence. Button edges
            // and actual role changes still render immediately above.
            if shakeEnabled, shake.nextDeadline(at: now) != nil { scheduleNext() }
            return false
        }
    }
    private func installSessionObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
                              (NSWorkspace.didWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(value) }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.excluded = self.theme?.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") ?? false
                self.waitOverlay.pointerChanged(window: 0)
                self.waitOverlay.setSuspended(self.paused || self.scenes.missionControl)
                self.sceneActivity()
                self.lastSeed = -1; self.registeredMatch = false
                self.reconcileRelease(); self.tick()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.waitOverlay.pointerChanged(window: 0)
                self.sceneActivity()
                self.lastSeed = -1; self.scenes.check(force: true); self.tick()
            }
        })
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = value; self?.suspend(value) }
            })
        }
    }
    private func suspend(_ value: Bool) {
        suspended = value
        waitOverlay.setSuspended(paused || scenes.missionControl)
        clearTemporary()
        machine.reset(now: now); roleID = nil; roleAliases.removeAll(); lastSeed = -1; armTimer(after: 0.008)
    }
    private func fail(_ error: Error) { let message = error.localizedDescription; _ = stop(); self.error = message }
}
