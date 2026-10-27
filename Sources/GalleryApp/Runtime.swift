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
    private let overlay = CursorOverlay()
    private var originals: [String: [String: Any]] = [:]
    private var normal: [String: [String: Any]] = [:]
    private var matcher = CursorMatcher()
    private var roleID: String?
    private var roleAliases: [String] = []
    private var machine = InteractionMachine(now: ProcessInfo.processInfo.systemUptime)
    private var timer: Timer?
    private let observation = MouseObservation()
    private var edges = MouseEdgeTracker(downs: 0, ups: 0)
    private var lastLocation = NSEvent.mouseLocation
    private var lastScroll: UInt32 = 0
    private var activity: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var suspended = false
    private var locked = false
    private var lastProbe = 0.0
    private var lastSeed: Int32 = -1
    private var unknownTicks = 0
    private var recoveryOverride: URL?
    init(recoveryURL: URL? = nil) { recoveryOverride = recoveryURL }
    #if GALLERY_RUNTIME_CHECKS
    var testPhysicalDown: Bool?
    func injectObserved(_ type: CGEventType) { handle(type) }
    var renderedFrame: Data? { overlay.displayedFrame }
    var overlayVisible: Bool { overlay.visible }
    #endif
    private var journalURL: URL {
        if let recoveryOverride { return recoveryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery/recovery.plist")
    }
    var hasRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    var diagnostics: String { GLCursorBridge.diagnostics() + " · " + (observation.active ? "会话监听" : "鼠标计数监听") }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var currentRole: CursorRole? { theme?.roles.first { $0.id == roleID } }
    private func counter(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: type) }

    func start(_ theme: GalleryTheme) {
        guard !enabled else { return }
        var theme = theme
        if !theme.roles.contains(where: { $0.id == "com.apple.cursor.0" }),
           var arrow = theme.roles.first(where: { $0.id == "com.apple.coregraphics.Arrow" }) {
            arrow.id = "com.apple.cursor.0"; theme.roles.append(arrow)
        }
        do {
            try theme.validate()
            guard GLCursorBridge.available() else { throw ThemeError.invalid("此系统未提供所需光标接口。编辑器仍可使用。") }
            if hasRecovery { throw ThemeError.invalid("存在上次未完成的恢复记录。请先点击恢复上次光标。") }
            let initialCursor = GLCursorBridge.currentCursor().flatMap { try? CursorImages.fromCape($0) }
            var backup: [String: [String: Any]] = [:], base: [String: [String: Any]] = [:]
            matcher = CursorMatcher()
            for role in theme.roles where !CursorCatalog.assetOnly(role.id) {
                guard let old = GLCursorBridge.readCursor(role.id),
                      let restored = try? CursorImages.fromCape(old), restored.frames.count <= 24 else { continue }
                backup[role.id] = old
                base[role.id] = try CursorImages.capeDictionary(role.clip(.normal)!)
                matcher.add(restored, role: role.id)
                matcher.add(role.clip(.normal)!, role: role.id)
                if let standard = GLCursorBridge.standardCursor(role.id), let clip = try? CursorImages.fromCape(standard) {
                    matcher.add(clip, role: role.id)
                }
            }
            guard !backup.isEmpty else { throw ThemeError.invalid("未能备份任何对应系统光标，未进行替换。") }
            let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: journalURL, options: .atomic)
            originals = backup; normal = base; self.theme = theme
            let initialRoles = initialCursor.map { matcher.match($0).filter { base[$0] != nil } } ?? []
            // Static resources use Mousecape's native path. Only interactive
            // states use the passive display layer, so normal hover detection
            // always observes a visible system cursor, including resize roles.
            _ = GLCursorBridge.clearCoreCursorCache()
            for id in base.keys.sorted() { try register(base[id]!, id: id, refresh: false) }
            enabled = true; machine.reset(now: now); suspended = false; locked = false
            edges = MouseEdgeTracker(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp))
            lastLocation = NSEvent.mouseLocation; lastScroll = counter(.scrollWheel)
            observation.onEvent = { [weak self] type in self?.handle(type) }
            observation.start(); installSessionObservers()
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                reason: "保持已启用的交互光标在关闭编辑窗口后继续响应")
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            status = "已启用 · \(base.count) 个系统光标 · 关闭窗口后继续运行"
            roleAliases = initialRoles
            roleID = initialRoles.contains("com.apple.coregraphics.Arrow") ? "com.apple.coregraphics.Arrow" : initialRoles.first
            render()
        } catch {
            let message = error.localizedDescription
            if !originals.isEmpty { _ = stop() }
            self.error = message
        }
    }
    @discardableResult
    func stop() -> Bool {
        timer?.invalidate(); timer = nil; observation.stop()
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
        _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        if failures.isEmpty {
            if !originals.isEmpty { try? FileManager.default.removeItem(at: journalURL) }
            originals.removeAll(); status = "已停用 · 已恢复启用前的光标"
        } else {
            error = "部分光标恢复失败，恢复记录已保留。请再次恢复，必要时注销登录。"
            status = "需要恢复光标"
        }
        roleAliases.removeAll()
        roleID = nil; theme = nil; machine.reset(now: now); lastProbe = 0; lastSeed = -1
        return failures.isEmpty
    }
    func recover() {
        guard !enabled else { _ = stop(); return }
        do {
            let data = try Data(contentsOf: journalURL)
            guard let backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]], !backup.isEmpty else {
                throw ThemeError.invalid("恢复记录损坏。")
            }
            originals = backup; _ = GLCursorBridge.setBackgroundCursorUpdates(true); _ = stop()
        } catch { self.error = error.localizedDescription }
    }
    func requestInputAccess() {
        _ = CGRequestListenEventAccess()
        if enabled { observation.stop(); observation.onEvent = { [weak self] in self?.handle($0) }; observation.start() }
    }
    private func register(_ dictionary: [String: Any], id: String, refresh: Bool = true) throws {
        let code = GLCursorBridge.updateCursor(dictionary, identifier: id, refresh: refresh)
        guard code == 0 else { throw ThemeError.invalid("光标注册失败：\(id)，错误 \(code)。") }
    }
    private func updateIdentification(force: Bool = false) {
        let seed = GLCursorBridge.cursorSeed()
        guard force || now - lastProbe > 0.12 || seed != lastSeed else { return }
        lastProbe = now; lastSeed = seed
        guard let data = GLCursorBridge.currentCursor(), let clip = try? CursorImages.fromCape(data) else { return }
        lastSeed = GLCursorBridge.cursorSeed()
        let found = matcher.match(clip).filter { normal[$0] != nil }
        if found.isEmpty { unknownTicks += 1 } else { unknownTicks = 0 }
        guard !found.isEmpty || unknownTicks >= 2 else { return }
        guard Set(found) != Set(roleAliases) else { return }
        do { try clearTemporary() } catch { fail(error); return }
        roleAliases = found
        roleID = found.contains("com.apple.coregraphics.Arrow") ? "com.apple.coregraphics.Arrow" : found.first
        machine.reset(now: now)
        // Unknown cursors only suspend this role; observation keeps running.
        if roleID == nil { status = "自定义光标 · 等待已知状态后自动恢复" }
    }
    private func clearTemporary() throws {
        try overlay.hide()
    }
    private var paused: Bool {
        suspended || locked || (theme?.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") ?? false)
    }
    private func tick() {
        guard enabled, let theme else { return }
        guard !paused else {
            do { try clearTemporary() } catch { fail(error) }
            machine.reset(now: now); roleID = nil; roleAliases.removeAll()
            edges = MouseEdgeTracker(downs: counter(.leftMouseDown), ups: counter(.leftMouseUp)); return
        }
        if machine.motion == .normal { updateIdentification() }
        let downs = counter(.leftMouseDown), ups = counter(.leftMouseUp)
        var physical = CGEventSource.buttonState(.combinedSessionState, button: .left)
        #if GALLERY_RUNTIME_CHECKS
        physical = testPhysicalDown ?? physical
        #endif
        let polled = edges.observe(downs: downs, ups: ups, isDown: physical)
        var usePolledEdges = !observation.active
        #if GALLERY_RUNTIME_CHECKS
        if testPhysicalDown != nil { usePolledEdges = false }
        #endif
        if usePolledEdges { for edge in polled { handle(edge == .down ? .leftMouseDown : .leftMouseUp) } }
        let location = NSEvent.mouseLocation, scroll = counter(.scrollWheel)
        if location != lastLocation || scroll != lastScroll { machine.activity(now: now) }
        lastLocation = location; lastScroll = scroll
        if machine.buttonDown, !physical { machine.up(now: now, releaseDuration: currentRole?.clip(.release)?.duration, enabled: theme.clickEnabled) }
        machine.tick(now: now, idleDelay: theme.idleDelay,
            idleEnabled: theme.idleEnabled && currentRole?.clip(.idle) != nil && NSEvent.pressedMouseButtons == 0)
        render()
    }
    private func render() {
        guard enabled, let role = currentRole else { return }
        let motion = role.clip(machine.motion) == nil ? .normal : machine.motion
        guard let clip = role.clip(motion) else { return }
        do {
            if motion == .normal { try overlay.hide() }
            else { try overlay.show(clip, key: role.id + ":" + motion.rawValue, loops: motion.loops, now: now) }
            let text = "\(role.name) · \(motion.title) · 后台运行中"
            if status != text { status = text }
        } catch { fail(error) }
    }
    private func handle(_ type: CGEventType) {
        guard enabled, !paused, let theme else { return }
        if machine.motion == .idle { machine.activity(now: now); try? overlay.hide() }
        if type == .leftMouseDown && machine.motion == .normal { updateIdentification(force: true) }
        switch type {
        case .leftMouseDown:
            machine.down(now: now, pressDuration: currentRole?.clip(.press)?.duration,
                         enabled: theme.clickEnabled, split: currentRole?.splitClickAnimation ?? false,
                         releaseDuration: currentRole?.clip(.release)?.duration)
        case .leftMouseUp:
            machine.up(now: now, releaseDuration: currentRole?.clip(.release)?.duration, enabled: theme.clickEnabled)
        default: machine.activity(now: now)
        }
        render()
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
                self.machine.reset(now: self.now); self.roleID = nil; self.roleAliases.removeAll(); self.lastProbe = 0
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
        machine.reset(now: now); roleID = nil; roleAliases.removeAll(); lastProbe = 0
    }
    private func fail(_ error: Error) { let message = error.localizedDescription; _ = stop(); self.error = message }
}
