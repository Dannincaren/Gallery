import AppKit
import Combine
import GalleryCore
import GalleryNative

@MainActor
final class CursorRuntime: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "未启用 · 编辑与预览不会更改系统光标"
    @Published var error: String?
    private var theme: GalleryTheme?
    private var roles: [String: CursorRole] = [:]
    private var canonicalRoles: [String: String] = [:]
    private var prepared: PreparedCursors?
    private let renderer = SystemCursorRenderer()
    private var originals: [String: [String: Any]] = [:]
    private var normal: [String: [String: Any]] = [:]
    private var recognition: CursorRecognition?
    private var recognizing = false
    private var generation = 0
    private var roleID: String?
    private var roleRevision = 0
    private var roleAliases: [String] = []
    private var machine = InteractionMachine(now: ProcessInfo.processInfo.systemUptime)
    private var normalClocks = RoleAnimationClocks()
    private var timer: Timer?
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
    private var recoveryOverride: URL?
    init(recoveryURL: URL? = nil) { recoveryOverride = recoveryURL }
    func setScale(_ value: Double) {
        guard value.isFinite else { return }
        pointerScale = min(3, max(0.5, value)); registeredMatch = false; render()
    }
    func setRoleScale(_ value: Double, for identifier: String) {
        guard value.isFinite, roles[identifier] != nil else { return }
        let family = CursorCatalog.family(identifier)
        for id in roles.keys where CursorCatalog.family(id) == family { roles[id]?.scale = min(3, max(0.5, value)) }
        registeredMatch = false; render()
    }
    func setShakeEnabled(_ value: Bool) { shakeEnabled = value; shake.reset(); render(); scheduleNext() }
    #if GALLERY_RUNTIME_CHECKS
    var testPhysicalDown: Bool?
    func injectObserved(_ type: CGEventType, timestamp: Double? = nil) { handle(type, timestamp: timestamp) }
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
    var testEffectiveIdleDelay: Double { idleDelay }
    func testScene(_ value: Bool?) { scenes.testOverride = value; scenes.check(force: true) }
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
    private var currentRole: CursorRole? { roleID.flatMap { roles[$0] } }
    private var idleDelay: Double { currentRole?.idleDelay(default: theme?.idleDelay ?? 8) ?? theme?.idleDelay ?? 8 }
    func setRoleIdleDelay(_ value: Double?, for identifier: String) {
        guard value == nil || (value!.isFinite && (1...600).contains(value!)) else { return }
        let family = CursorCatalog.family(identifier)
        for id in roles.keys where CursorCatalog.family(id) == family { roles[id]?.idleDelayOverride = value }
        scheduleNext()
    }
    private func counter(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: type) }

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
            guard GLCursorBridge.available() else { throw ThemeError.invalid("此系统未提供所需光标接口。编辑器仍可使用。") }
            guard !hasRecovery else { throw ThemeError.invalid("存在上次未完成的恢复记录。请先恢复上次光标。") }
            var backup: [String: [String: Any]] = [:], base: [String: [String: Any]] = [:]
            var visualClips: [String: CursorClip] = [:]
            var matcher = CursorMatcher()
            for role in theme.roles where !CursorCatalog.assetOnly(role.id) {
                if let standard = GLCursorBridge.standardCursor(role.id) { matcher.addRepresentations(standard, role: role.id) }
                guard let old = GLCursorBridge.readCursor(role.id), let restored = try? CursorImages.fromCape(old), restored.frames.count <= 24 else { continue }
                matcher.addRepresentations(old, role: role.id)
                backup[role.id] = old
                if !role.usesNative {
                    var clip = role.clip(.normal)!.scaled(by: pointerScale * role.scale)
                    visualClips[role.id] = clip
                    // Foreground apps reselect IBeam on every cursor-region
                    // update. An animated registered resource restarts then;
                    // Gallery owns the continuous clock and cached frame loop.
                    if clip.frames.count > 1 && !CursorCatalog.isResize(role.id) { clip.frames = [clip.frames[0]] }
                    base[role.id] = try CursorImages.capeDictionary(clip)
                    matcher.add(role.clip(.normal)!, role: role.id, applied: true)
                }
            }
            guard !base.isEmpty || theme.roles.contains(where: \.usesNative) else { throw ThemeError.invalid("未能备份对应系统光标，未进行替换。") }
            prepared = try PreparedCursors(roles: theme.roles.filter { base[$0.id] != nil })
            if base.isEmpty { backup.removeAll() }
            if !backup.isEmpty {
                let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
                try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: journalURL, options: .atomic)
            }
            originals = backup; normal = base; self.theme = theme
            roles = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, $0) })
            registeredScales = Dictionary(uniqueKeysWithValues: theme.roles.map { ($0.id, pointerScale * $0.scale) })
            canonicalRoles = Dictionary(uniqueKeysWithValues: theme.roles.map { role in
                (role.id, theme.roles.first(where: { CursorCatalog.family($0.id) == CursorCatalog.family(role.id) })!.id)
            })
            renderer.configureNativeNormals(base, visualClips: visualClips)
            if let arrow = theme.roles.first(where: { CursorCatalog.isArrow($0.id) }) {
                for motion in [Motion.release, .hold] {
                    if let clip = prepared?.clip(role: arrow.id, motion: motion) {
                        renderer.warmInteraction(clip, role: arrow.id, motion: motion, scale: pointerScale * arrow.scale)
                    }
                }
            }
            if let text = theme.roles.first(where: { $0.id == "com.apple.coregraphics.IBeam" }),
               let clip = prepared?.clip(role: text.id, motion: .normal), clip.frames.count > 1 {
                renderer.warmInteraction(clip, role: text.id, motion: .normal, scale: pointerScale * text.scale, limit: 96)
            }
            recognition = CursorRecognition(matcher: matcher); generation += 1
            if !base.isEmpty { _ = GLCursorBridge.clearCoreCursorCache() }
            for id in base.keys.sorted() {
                let code = GLCursorBridge.updateCursor(base[id]!, identifier: id, refresh: false)
                guard code == 0 else { throw ThemeError.invalid("光标注册失败：\(id)，错误 \(code)。") }
            }
            enabled = true; machine.reset(now: now); normalClocks.reset(); suspended = false; locked = false; wasPaused = false
            excluded = theme.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            inputCounters = MouseCounterLedger(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp)); counterGesture = false
            lastLocation = NSEvent.mouseLocation; lastScroll = counter(.scrollWheel); lastSeed = -1
            observation.onEvent = { [weak self] type in
                guard let self else { return }
                self.handle(type, timestamp: self.observation.latestTimestamp, position: self.observation.latestPosition, observed: true)
            }
            observation.start(); installSessionObservers()
            scenes.onChange = { [weak self] active in
                guard let self, self.enabled else { return }
                self.lastSeed = -1; self.registeredMatch = false
                if active { self.applyIdentification(CursorIdentification(roles: ["com.apple.coregraphics.Arrow"])) }
                self.tick()
            }
            scenes.check(force: true)
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "保持交互光标响应")
            lastLeftEdge = -Double.infinity; lastLeftDown = 0; lastLeftUp = 0; lastWatchdog = now
            lastCornerCheck = 0; tickCount = 0; unknownSince = nil
            status = "已启用 · 关闭窗口后继续运行"; updateIdentification(); armTimer(after: 0.008)
        } catch {
            let message = error.localizedDescription
            if !originals.isEmpty { _ = stop() }
            self.error = message
        }
    }
    @discardableResult
    func stop() -> Bool {
        timer?.invalidate(); timer = nil; observation.stop(); scenes.onChange = nil; generation += 1; recognizing = false; recognition = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; distributedObservers.removeAll()
        enabled = false
        var failures: [String] = []
        renderer.stop(restoring: roleID.flatMap { originals[$0] })
        if !originals.isEmpty { _ = GLCursorBridge.clearCoreCursorCache() }
        for id in originals.keys.sorted() {
            if GLCursorBridge.updateCursor(originals[id]!, identifier: id, refresh: false) != 0 { failures.append(id) }
        }
        GLCursorBridge.setDockCursorOverride(false); _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        if failures.isEmpty {
            if !originals.isEmpty { try? FileManager.default.removeItem(at: journalURL) }
            originals.removeAll(); status = "已停用 · 已恢复启用前的光标"
        } else { error = "部分光标恢复失败，恢复记录已保留。请再次恢复，必要时注销登录。"; status = "需要恢复光标" }
        roleAliases.removeAll(); roles.removeAll(); canonicalRoles.removeAll(); normal.removeAll(); prepared = nil
        roleID = nil; theme = nil; registeredMatch = false; registeredScales.removeAll(); shake.reset()
        machine.reset(now: now); lastProbe = 0; lastSeed = -1; dockGesture = false
        return failures.isEmpty
    }
    func recover() {
        guard !enabled else { _ = stop(); return }
        do {
            guard let backup = try PropertyListSerialization.propertyList(from: Data(contentsOf: journalURL), format: nil) as? [String: [String: Any]], !backup.isEmpty else { throw ThemeError.invalid("恢复记录损坏。") }
            originals = backup; _ = stop()
        } catch { self.error = error.localizedDescription }
    }
    func requestInputAccess() {
        _ = CGRequestListenEventAccess()
        if enabled { observation.start(); armTimer(after: 0.008) }
    }
    private func updateIdentification() {
        #if GALLERY_RUNTIME_CHECKS
        if testRecognitionSuspended && !renderer.needsConfirmation { return }
        #endif
        if editorCorner.active { return }
        let seed = GLCursorBridge.cursorSeed()
        guard !scenes.missionControl else { return }
        if !renderer.needsConfirmation, !renderer.owns(seed: seed), let role = renderer.knownRole(seed: seed), roles[role] != nil {
            lastSeed = seed
            applyIdentification(CursorIdentification(roles: [role])); return
        }
        guard !recognizing, let recognition, !renderer.owns(seed: seed) || renderer.needsConfirmation else { return }
        guard seed != lastSeed || renderer.needsConfirmation || now - lastProbe > 1 else { return }
        lastProbe = now; recognizing = true
        let currentGeneration = generation
        let currentRoleRevision = roleRevision
        let pending = renderer.pendingImage
        let referenceRevision = renderer.imageRevision
        let recoveryStarted = machine.motionStartedAt
        var recovery = renderer.nativeRecoveryImages
        recovery?.releasing = machine.motion == .release
        recognition.probe(pendingImage: pending?.fingerprint, nativeImages: renderer.nativeGuardFingerprints,
                          nativeRecovery: recovery) { [weak self] seed, found, ownImage, recoveryIndex in
            DispatchQueue.main.async {
                if ownImage {
                    guard let self, self.enabled, currentGeneration == self.generation else { return }
                    self.recognizing = false
                    guard currentRoleRevision == self.roleRevision,
                          seed == GLCursorBridge.cursorSeed() else { self.armTimer(after: 0.001); return }
                    if self.renderer.confirmDisplayed(seed: seed, revision: referenceRevision) {
                        // A press/up may have arrived while that image was in
                        // flight. Present the latest phase immediately on ack.
                        self.render(); self.scheduleNext()
                    } else { self.armTimer(after: 0.001) }
                    return
                }
                self?.acceptObservation(seed: seed, found: found, generation: currentGeneration, revision: currentRoleRevision,
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
        guard enabled, capturedGeneration == generation else { return }
        recognizing = false
        #if GALLERY_RUNTIME_CHECKS
        if testRecognitionSuspended { return }
        #endif
        guard revision == roleRevision else { armTimer(after: 0.001); return }
        // The captured image must still be the visible resource. Our current
        // frame does not make an older foreign observation valid again.
        guard !renderer.owns(seed: seed) else { return }
        guard let found, seed == GLCursorBridge.cursorSeed() else { armTimer(after: 0.001); return }
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
        let ids = scenes.missionControl && roles["com.apple.coregraphics.Arrow"] != nil
            ? ["com.apple.coregraphics.Arrow"] : found.roles.filter { roles[$0] != nil }
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
            roleRevision += 1
            roleID = selected
            // Drag/drop and focus changes can change the cursor family in
            // the middle of a click. Preserve that gesture's phase and epoch.
            if machine.motion == .normal || machine.motion == .idle { machine.reset(now: now) }
            if selected == nil {
                renderer.passThrough()
                status = "自定义光标 · 等待已知状态后自动恢复"
            }
        }
        reconcileRelease(); render(); scheduleNext()
    }
    private func clearTemporary() { renderer.passThrough(); shake.reset(); normalClocks.reset() }
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
        machine.up(now: timestamp, releaseDuration: currentRole?.clip(.release)?.duration, enabled: theme?.clickEnabled ?? false)
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
        let due = Date().addingTimeInterval(max(0.001, delay))
        if let timer, timer.isValid, timer.fireDate <= due { return }
        timer?.invalidate()
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer = nil; self?.tick() }
        }
        let precise = renderer.nextFrameDeadline != nil || machine.transitionDeadline != nil || renderer.needsConfirmation
        timer.tolerance = precise ? 0 : min(0.02, delay * 0.1)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func scheduleNext() {
        guard enabled else { return }
        let delay = PointerSchedule.delay(now: now,
            polling: !observation.active || counterGesture, paused: paused,
            frameDeadline: [renderer.nextFrameDeadline, shakeEnabled ? shake.nextDeadline(at: now) : nil].compactMap { $0 }.min(), transitionDeadline: machine.transitionDeadline,
            idleDeadline: (theme?.idleEnabled == true && currentRole?.clip(.idle) != nil && !machine.buttonDown && machine.motion == .normal)
                ? machine.lastActivity + idleDelay : nil)
        armTimer(after: renderer.needsConfirmation ? min(delay, 0.002) : delay)
    }
    private func tick() {
        guard enabled, let theme else { return }; tickCount += 1
        if paused {
            if !wasPaused { clearTemporary(); machine.reset(now: now); wasPaused = true }
            scheduleNext(); return
        }
        if wasPaused { wasPaused = false; lastSeed = -1; inputCounters = MouseCounterLedger(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp)); counterGesture = false }
        if !observation.active || counterGesture || now - lastWatchdog >= 0.19 {
            lastWatchdog = now; pollInput(); scenes.check()
        }
        let location = NSEvent.mouseLocation
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
        reconcileRelease()
        machine.tick(now: now, idleDelay: idleDelay, idleEnabled: theme.idleEnabled && currentRole?.clip(.idle) != nil)
        updateIdentification(); render(); scheduleNext()
    }
    private func render() {
        guard enabled, !paused, let role = currentRole else { return }
        reconcileRelease()
        let currentSeed = GLCursorBridge.cursorSeed()
        // Never overwrite an as-yet unrecognized foreground cursor with the
        // previous role. Our own submitted animation seeds are never matched.
        guard scenes.missionControl || currentSeed == lastSeed || renderer.owns(seed: currentSeed) else { return }
        if role.usesNative || normal[role.id] == nil {
            renderer.passThrough(); updateStatus("\(role.name) · 系统原有光标"); return
        }
        let interacting = [.press, .hold, .release].contains(machine.motion)
        if !interacting { dockGesture = false }
        let shellClick = (scenes.missionControl || dockGesture) && interacting
        let motion: Motion = scenes.missionControl && !shellClick ? .normal : (role.clip(machine.motion) == nil ? .normal : machine.motion)
        let magnification = shakeEnabled ? shake.scale(at: now) : 1
        let scale = pointerScale * role.scale * magnification
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
            let geometry = clip.clip.scaled(by: scale)
            renderer.passThrough(frame: clip.frames[0].data, size: CGSize(width: geometry.width, height: geometry.height))
        } else {
            let started = motion == .normal ? normalClocks.start(for: CursorCatalog.family(role.id), suggested: machine.motionStartedAt, now: now) : machine.motionStartedAt
            renderer.present(clip, role: role.id, motion: motion, scale: scale, started: started, now: now,
                staticOnly: scenes.missionControl && !shellClick, synchronizeRegistration: magnification == 1 && abs(scale - (registeredScales[role.id] ?? -1)) < 0.005,
                shell: shellClick)
        }
        updateStatus(scenes.missionControl ? "调度中心 · \(shellClick ? motion.title : "主题静态光标")" : "\(role.name) · \(motion.title) · 系统光标通道")
    }
    private func updateStatus(_ text: String) { if status != text { status = text } }
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
            lastLeftEdge = timestamp; lastLocation = position ?? NSEvent.mouseLocation
            #if GALLERY_RUNTIME_CHECKS
            inputRecords.append(["edge": type == .leftMouseDown ? "down" : "up", "at": now, "eventAt": timestamp, "observed": observed])
            if inputRecords.count > 200 { inputRecords.removeFirst() }
            #endif
            if type == .leftMouseDown {
                lastLeftDown = timestamp
                dockGesture = observed && scenes.isDockWindow(observation.latestWindowID)
                normalClocks.reset()
                machine.down(now: timestamp, pressDuration: currentRole?.clip(.press)?.duration, enabled: theme.clickEnabled,
                    split: currentRole?.splitClickAnimation ?? false, releaseDuration: currentRole?.clip(.release)?.duration)
            } else {
                lastLeftUp = timestamp
                machine.up(now: timestamp, releaseDuration: currentRole?.clip(.release)?.duration, enabled: theme.clickEnabled)
            }
            if observed {
                acknowledgeCounter(type == .leftMouseDown ? .down : .up); counterGesture = false
            }
            // A batch may contain down and up together. Consume the complete
            // batch before physical-state reconciliation credits a later edge.
            if observed || renderAfter { reconcileRelease() }
            machine.tick(now: now, idleDelay: idleDelay, idleEnabled: false)
            if renderAfter { updateIdentification(); render(); scheduleNext() }
            return true
        default:
            if wasIdle { tick(); return false }
            // Position is managed by macOS. Motion only needs to observe a
            // changed role; it must not create a 120Hz rendering timer.
            updateIdentification()
            if NSApp.isActive && now - lastCornerCheck >= 1.0 / 120 {
                lastCornerCheck = now; synchronizeEditorCorner(at: lastLocation)
            }
            if shakeEnabled, shake.nextDeadline(at: now) != nil { render(); scheduleNext() }
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
                self.lastSeed = -1; self.registeredMatch = false
                self.reconcileRelease(); self.tick()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastSeed = -1; self?.scenes.check(force: true); self?.tick() }
        })
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = value; self?.suspend(value) }
            })
        }
    }
    private func suspend(_ value: Bool) {
        suspended = value
        clearTemporary()
        machine.reset(now: now); roleID = nil; roleAliases.removeAll(); lastSeed = -1; armTimer(after: 0.008)
    }
    private func fail(_ error: Error) { let message = error.localizedDescription; _ = stop(); self.error = message }
}
