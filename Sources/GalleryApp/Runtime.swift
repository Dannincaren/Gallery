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
    private var originals: [String: [String: Any]] = [:]
    private var normal: [String: [String: Any]] = [:]
    private var prepared: [String: [String: [String: Any]]] = [:]
    private var signatures: [String: [String]] = [:]
    private var roleID: String?
    private var roleAliases: [String] = []
    private var temporaryRoles: [String] = []
    private var temporarySignatures = Set<String>()
    private var appliedMotion = Motion.normal
    private var machine = InteractionMachine(now: ProcessInfo.processInfo.systemUptime)
    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var suspended = false
    private var locked = false
    private var unknownTicks = 0
    private var journalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery/recovery.plist")
    }
    var hasRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    var diagnostics: String { GLCursorBridge.diagnostics() }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start(_ theme: GalleryTheme) {
        guard !enabled else { return }
        do {
            try theme.validate()
            guard GLCursorBridge.available() else { throw ThemeError.invalid("此系统未提供所需光标接口。编辑器仍可使用。") }
            if hasRecovery { throw ThemeError.invalid("存在上次未完成的恢复记录。请先点击恢复上次光标。") }
            var backup: [String: [String: Any]] = [:]
            var base: [String: [String: Any]] = [:]
            var clips: [String: [String: [String: Any]]] = [:]
            signatures.removeAll()
            for role in theme.roles {
                // Never mutate a role unless its previous resource can be restored.
                guard let old = GLCursorBridge.readCursor(role.id) else { continue }
                let restored = try CursorImages.fromCape(old)
                guard restored.frames.count <= 24 else { continue }
                backup[role.id] = old
                base[role.id] = try CursorImages.capeDictionary(role.clip(.normal)!)
                clips[role.id] = try role.clips.mapValues { try CursorImages.capeDictionary($0) }
                addSignatures(restored, role: role.id)
                addSignatures(role.clip(.normal)!.sampled(), role: role.id)
            }
            guard !backup.isEmpty else { throw ThemeError.invalid("未能备份主题对应的系统光标，未进行任何替换。") }
            // Atomic, on-disk journal BEFORE the first global registration.
            let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: journalURL, options: .atomic)
            originals = backup; normal = base; prepared = clips; self.theme = theme
            for id in base.keys.sorted() { try register(base[id]!, id: id) }
            // Learn actual system renderings, including its scale/color conversion.
            for id in base.keys.sorted() {
                if let actual = GLCursorBridge.readCursor(id), let clip = try? CursorImages.fromCape(actual) { addSignatures(clip, role: id) }
            }
            enabled = true; machine.reset(now: now); suspended = false; locked = false
            installMonitors()
            guard globalMonitor != nil, localMonitor != nil else {
                throw ThemeError.invalid("鼠标监听未能启动。已恢复光标，请检查输入监控授权。")
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
            status = "已启用 · \(base.count) 种光标 · 跨应用交互"
        } catch {
            self.error = error.localizedDescription
            if !originals.isEmpty { stop() }
        }
    }
    @discardableResult
    func stop() -> Bool {
        timer?.invalidate(); timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; distributedObservers.removeAll()
        enabled = false
        var failures: [String] = []
        for id in originals.keys.sorted() {
            if GLCursorBridge.registerCursor(originals[id]!, identifier: id) != 0 { failures.append(id) }
        }
        if failures.isEmpty {
            if !originals.isEmpty { try? FileManager.default.removeItem(at: journalURL) }
            originals.removeAll()
            status = "已停用 · 已恢复启用前的光标"
        } else {
            error = "部分光标恢复失败，恢复记录已保留。请再次恢复，必要时注销登录。"
            status = "需要恢复光标"
        }
        temporaryRoles.removeAll(); temporarySignatures.removeAll(); roleAliases.removeAll()
        roleID = nil; theme = nil; machine.reset(now: now)
        return failures.isEmpty
    }
    func recover() {
        guard !enabled else { _ = stop(); return }
        do {
            let data = try Data(contentsOf: journalURL)
            guard let backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]], !backup.isEmpty else {
                throw ThemeError.invalid("恢复记录损坏。")
            }
            originals = backup
            _ = stop()
        } catch { self.error = error.localizedDescription }
    }
    func requestInputAccess() { _ = CGRequestListenEventAccess() }
    private func register(_ dictionary: [String: Any], id: String) throws {
        let code = GLCursorBridge.registerCursor(dictionary, identifier: id)
        guard code == 0 else { throw ThemeError.invalid("光标注册失败：\(id)，错误 \(code)。") }
    }
    private func addSignatures(_ clip: CursorClip, role: String) {
        for frame in clip.frames {
            if let signature = CursorImages.signature(frame, hotX: clip.hotX, hotY: clip.hotY, width: clip.width, height: clip.height),
               !(signatures[signature] ?? []).contains(role) { signatures[signature, default: []].append(role) }
        }
    }
    private func identify() -> String? {
        guard let data = GLCursorBridge.currentCursor(), let clip = try? CursorImages.fromCape(data),
              let signature = CursorImages.signature(clip.frames[0], hotX: clip.hotX, hotY: clip.hotY, width: clip.width, height: clip.height) else { return nil }
        if temporarySignatures.contains(signature), !temporaryRoles.isEmpty {
            roleAliases = temporaryRoles
            return roleID
        }
        guard let matches = signatures[signature] else { return nil }
        roleAliases = matches.sorted()
        if let roleID, matches.contains(roleID) { return roleID }
        return matches.sorted().first
    }
    private func clearTemporary() throws {
        for id in temporaryRoles { if let resource = normal[id] { try register(resource, id: id) } }
        temporaryRoles.removeAll(); temporarySignatures.removeAll(); appliedMotion = .normal
    }
    private func tick() {
        guard enabled, let theme else { return }
        let excluded = theme.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        guard !suspended, !locked, !excluded else {
            do { try clearTemporary() } catch { fail(error) }
            machine.reset(now: now); roleID = nil
            return
        }
        let found = identify()
        if found == nil { unknownTicks += 1 } else { unknownTicks = 0 }
        if found != roleID, found != nil || unknownTicks >= 2 {
            do { try clearTemporary() } catch { fail(error); return }
            roleID = found; machine.reset(now: now)
        }
        // Menus or a session transition can swallow mouse-up. Reconcile with
        // physical state so no animation can remain stuck in a held state.
        if machine.buttonDown, !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let role = theme.roles.first { $0.id == roleID }
            machine.up(now: now, releaseDuration: role?.clip(.release)?.duration, enabled: theme.clickEnabled)
        }
        machine.tick(now: now, idleDelay: theme.idleDelay,
                     idleEnabled: theme.idleEnabled && NSEvent.pressedMouseButtons == 0)
        render()
    }
    private func render() {
        guard enabled, let id = roleID, let role = theme?.roles.first(where: { $0.id == id }) else { return }
        let motion = role.clip(machine.motion) == nil ? .normal : machine.motion
        guard motion != appliedMotion else { return }
        do {
            try clearTemporary()
            if motion != .normal {
                // Identical bitmap/hotspot aliases cannot be disambiguated by
                // NSCursor. Update all matching known aliases, then restore all.
                for alias in roleAliases {
                    guard let resource = prepared[alias]?[motion.rawValue],
                          let clip = theme?.roles.first(where: { $0.id == alias })?.clip(motion)?.sampled() else { continue }
                    try register(resource, id: alias)
                    temporaryRoles.append(alias)
                    for frame in clip.frames {
                        if let signature = CursorImages.signature(frame, hotX: clip.hotX, hotY: clip.hotY, width: clip.width, height: clip.height) {
                            temporarySignatures.insert(signature)
                        }
                    }
                }
                appliedMotion = motion
            }
            status = "\(role.name) · \(motion.title)"
        } catch { fail(error) }
    }
    private func handle(_ event: NSEvent) {
        guard enabled, !suspended, !locked, let theme else { return }
        if theme.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") { return }
        if roleID == nil { roleID = identify() }
        let role = theme.roles.first { $0.id == roleID }
        switch event.type {
        case .leftMouseDown:
            machine.down(now: now, pressDuration: role?.clip(.press)?.duration, enabled: theme.clickEnabled)
        case .leftMouseUp:
            machine.up(now: now, releaseDuration: role?.clip(.release)?.duration, enabled: theme.clickEnabled)
        default: machine.activity(now: now)
        }
        render()
    }
    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }; return event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(false) }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.clearTemporary() } catch { self.fail(error) }
                self.machine.reset(now: self.now); self.roleID = nil
            }
        })
        // Best-effort lock fallback only; never attempt to monitor secure input.
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = value; self?.suspend(value) }
            })
        }
    }
    private func suspend(_ value: Bool) {
        suspended = value
        do { try clearTemporary() } catch { fail(error) }
        machine.reset(now: now); roleID = nil
    }
    private func fail(_ error: Error) {
        let message = error.localizedDescription
        _ = stop(); self.error = message
    }
}
