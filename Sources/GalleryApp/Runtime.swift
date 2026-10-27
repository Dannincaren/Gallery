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
    private var prepared: PreparedCursors?
    private let overlay = CursorOverlay()
    private var originals: [String: [String: Any]] = [:]
    private var normal: [String: [String: Any]] = [:]
    private var recognition: CursorRecognition?
    private var recognizing = false
    private var generation = 0
    private var roleID: String?
    private var roleAliases: [String] = []
    private var machine = InteractionMachine(now: ProcessInfo.processInfo.systemUptime)
    private var timer: Timer?
    private let observation = MouseObservation()
    private var edges = MouseEdgeTracker(downs: 0, ups: 0)
    private var lastLocation = NSEvent.mouseLocation
    private var lastScroll: UInt32 = 0
    private var lastDownCount: UInt32 = 0
    private var lastUpCount: UInt32 = 0
    private var lastScrollCheck = 0.0
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
        pointerScale = min(3, max(0.5, value)); render()
    }
    func setRoleScale(_ value: Double, for identifier: String) {
        guard value.isFinite, let name = roles[identifier]?.name else { return }
        for id in roles.keys where roles[id]?.name == name { roles[id]?.scale = min(3, max(0.5, value)) }
        render()
    }
    #if GALLERY_RUNTIME_CHECKS
    var testPhysicalDown: Bool?
    func injectObserved(_ type: CGEventType) { handle(type) }
    var renderedFrame: Data? { overlay.displayedFrame }
    var overlayVisible: Bool { overlay.visible }
    var overlaySize: CGSize { overlay.size }
    var overlayHideRepairs: Int { overlay.hideRepairs }
    var overlayPointerPosition: CGPoint? { overlay.pointerPosition }
    #endif
    private var journalURL: URL {
        recoveryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery/recovery.plist")
    }
    var hasRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    var diagnostics: String { GLCursorBridge.diagnostics() + " · " + (observation.active ? "会话监听" : "鼠标计数监听") }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var currentRole: CursorRole? { roleID.flatMap { roles[$0] } }
    private func counter(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: type) }

    func start(_ input: GalleryTheme) {
        guard !enabled else { return }
        var theme = input
        for (source, target) in [("com.apple.coregraphics.Arrow", "com.apple.cursor.0"), ("com.apple.coregraphics.IBeam", "com.apple.cursor.1")] {
            if !theme.roles.contains(where: { $0.id == target }), var role = theme.roles.first(where: { $0.id == source }) {
                role.id = target; theme.roles.append(role)
            }
        }
        do {
            try theme.validate()
            guard GLCursorBridge.available() else { throw ThemeError.invalid("此系统未提供所需光标接口。编辑器仍可使用。") }
            guard !hasRecovery else { throw ThemeError.invalid("存在上次未完成的恢复记录。请先恢复上次光标。") }
            var backup: [String: [String: Any]] = [:], base: [String: [String: Any]] = [:]
            var matcher = CursorMatcher()
            for role in theme.roles where !CursorCatalog.assetOnly(role.id) {
                if let standard = GLCursorBridge.standardCursor(role.id) { matcher.addRepresentations(standard, role: role.id) }
                guard let old = GLCursorBridge.readCursor(role.id), let restored = try? CursorImages.fromCape(old), restored.frames.count <= 24 else { continue }
                matcher.addRepresentations(old, role: role.id)
                backup[role.id] = old
                if !role.usesNative {
                    base[role.id] = try CursorImages.capeDictionary(role.clip(.normal)!)
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
            recognition = CursorRecognition(matcher: matcher); generation += 1
            if !base.isEmpty { _ = GLCursorBridge.clearCoreCursorCache() }
            for id in base.keys.sorted() {
                let code = GLCursorBridge.updateCursor(base[id]!, identifier: id, refresh: false)
                guard code == 0 else { throw ThemeError.invalid("光标注册失败：\(id)，错误 \(code)。") }
            }
            enabled = true; machine.reset(now: now); suspended = false; locked = false; wasPaused = false
            excluded = theme.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            edges = MouseEdgeTracker(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp))
            lastDownCount = counter(.leftMouseDown); lastUpCount = counter(.leftMouseUp)
            lastLocation = NSEvent.mouseLocation; lastScroll = counter(.scrollWheel); lastSeed = -1
            observation.onEvent = { [weak self] in self?.handle($0) }; observation.start(); installSessionObservers()
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "保持交互光标响应")
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            timer.tolerance = 0.001; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            status = "已启用 · 关闭窗口后继续运行"; updateIdentification()
        } catch {
            let message = error.localizedDescription
            if !originals.isEmpty { _ = stop() }
            self.error = message
        }
    }
    @discardableResult
    func stop() -> Bool {
        timer?.invalidate(); timer = nil; observation.stop(); generation += 1; recognizing = false; recognition = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; distributedObservers.removeAll()
        enabled = false
        var failures: [String] = []
        do { try overlay.hide() } catch { failures.append("overlay"); self.error = error.localizedDescription }
        if !originals.isEmpty { _ = GLCursorBridge.clearCoreCursorCache() }
        for id in originals.keys.sorted() {
            if GLCursorBridge.updateCursor(originals[id]!, identifier: id, refresh: false) != 0 { failures.append(id) }
        }
        GLCursorBridge.setDockCursorOverride(false); _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        if failures.isEmpty {
            if !originals.isEmpty { try? FileManager.default.removeItem(at: journalURL) }
            originals.removeAll(); status = "已停用 · 已恢复启用前的光标"
        } else { error = "部分光标恢复失败，恢复记录已保留。请再次恢复，必要时注销登录。"; status = "需要恢复光标" }
        roleAliases.removeAll(); roles.removeAll(); normal.removeAll(); prepared = nil
        roleID = nil; theme = nil; machine.reset(now: now); lastProbe = 0; lastSeed = -1
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
        if enabled { observation.stop(); observation.onEvent = { [weak self] in self?.handle($0) }; observation.start() }
    }
    private func updateIdentification() {
        guard !recognizing, let recognition else { return }
        let seed = GLCursorBridge.cursorSeed()
        guard seed != lastSeed || now - lastProbe > 1 else { return }
        lastProbe = now; recognizing = true
        let currentGeneration = generation
        recognition.probe { [weak self] seed, found in
            DispatchQueue.main.async {
                guard let self, self.enabled, currentGeneration == self.generation else { return }
                self.recognizing = false
                guard let found, seed == GLCursorBridge.cursorSeed() else { return }
                self.lastSeed = seed; self.applyIdentification(found)
            }
        }
    }
    private func applyIdentification(_ found: CursorIdentification) {
        let ids = found.roles.filter { roles[$0] != nil }
        let selected = ids.contains("com.apple.coregraphics.Arrow") ? "com.apple.coregraphics.Arrow" : ids.first
        if ids != roleAliases {
            roleAliases = ids; roleID = selected
            let held = machine.buttonDown; machine.reset(now: now)
            if held { machine.down(now: now, pressDuration: nil, enabled: theme?.clickEnabled ?? false, split: currentRole?.splitClickAnimation ?? false) }
            if selected == nil {
                do { try overlay.hide() } catch { fail(error) }
                status = "自定义光标 · 等待已知状态后自动恢复"
            }
        }
        render()
    }
    private func clearTemporary() throws { try overlay.hide() }
    private var paused: Bool { suspended || locked || excluded }
    private func tick() {
        guard enabled, let theme else { return }
        if paused {
            if !wasPaused { do { try overlay.hide() } catch { fail(error) }; machine.reset(now: now); wasPaused = true }
            return
        }
        if wasPaused { wasPaused = false; lastSeed = -1; edges = MouseEdgeTracker(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp)) }
        if !observation.active {
            let downs = counter(.leftMouseDown), ups = counter(.leftMouseUp)
            var physical = downs != lastDownCount && ups == lastUpCount
            if machine.buttonDown || (downs != lastDownCount && ups != lastUpCount) {
                physical = CGEventSource.buttonState(.combinedSessionState, button: .left)
            }
            lastDownCount = downs; lastUpCount = ups
            #if GALLERY_RUNTIME_CHECKS
            physical = testPhysicalDown ?? physical
            #endif
            let polled = edges.observe(downs: downs, ups: ups, isDown: physical)
            var useEdges = true
            #if GALLERY_RUNTIME_CHECKS
            useEdges = testPhysicalDown == nil
            #endif
            if useEdges { for edge in polled { handle(edge == .down ? .leftMouseDown : .leftMouseUp) } }
            if machine.buttonDown && !physical { machine.up(now: now, releaseDuration: currentRole?.clip(.release)?.duration, enabled: theme.clickEnabled) }
        }
        let location = NSEvent.mouseLocation
        if location != lastLocation { machine.activity(now: now); lastLocation = location }
        if !observation.active && now - lastScrollCheck > 0.04 {
            lastScrollCheck = now
            let scroll = counter(.scrollWheel)
            if scroll != lastScroll { machine.activity(now: now); lastScroll = scroll }
        }
        machine.tick(now: now, idleDelay: theme.idleDelay, idleEnabled: theme.idleEnabled && currentRole?.clip(.idle) != nil)
        // Draw/move first. Recognition work never blocks event delivery.
        render()
        updateIdentification()
    }
    private func render() {
        guard enabled, !paused, let role = currentRole else { return }
        do {
            if role.usesNative || normal[role.id] == nil {
                try overlay.hide()
                let text = "\(role.name) · 系统原有光标"
                if status != text { status = text }; return
            }
            let motion = role.clip(machine.motion) == nil ? .normal : machine.motion
            let scale = pointerScale * role.scale
            if let clip = prepared?.clip(role: role.id, motion: motion) {
                try overlay.show(clip, scale: scale, key: role.id + ":" + motion.rawValue, loops: motion.loops, now: now, position: lastLocation)
            }
            let text = "\(role.name) · \(motion.title) · 后台运行中"
            if status != text { status = text }
        } catch { fail(error) }
    }
    private func handle(_ type: CGEventType) {
        guard enabled, !paused, let theme else { return }
        let wasIdle = machine.motion == .idle
        machine.activity(now: now)
        switch type {
        case .leftMouseDown:
            lastLocation = NSEvent.mouseLocation
            machine.down(now: now, pressDuration: currentRole?.clip(.press)?.duration, enabled: theme.clickEnabled,
                split: currentRole?.splitClickAnimation ?? false, releaseDuration: currentRole?.clip(.release)?.duration)
            render()
        case .leftMouseUp:
            lastLocation = NSEvent.mouseLocation
            machine.up(now: now, releaseDuration: currentRole?.clip(.release)?.duration, enabled: theme.clickEnabled); render()
        default: if wasIdle { render() }
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
                do { try self.clearTemporary() } catch { self.fail(error) }
                self.excluded = self.theme?.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") ?? false
                self.machine.reset(now: self.now); self.roleID = nil; self.roleAliases.removeAll(); self.lastSeed = -1
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
        do { try clearTemporary() } catch { fail(error) }
        machine.reset(now: now); roleID = nil; roleAliases.removeAll(); lastSeed = -1
    }
    private func fail(_ error: Error) { let message = error.localizedDescription; _ = stop(); self.error = message }
}
