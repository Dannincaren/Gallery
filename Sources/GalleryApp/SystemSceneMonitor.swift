import AppKit
import GalleryNative

/// Read only the shell's window owner/layer metadata; no window images, AX
/// permissions or keyboard monitoring are needed for Mission Control.
@MainActor
final class SystemSceneMonitor {
    var onChange: ((Bool) -> Void)?
    var onActivity: (() -> Void)?
    private var lifecycle: GLSceneObservation?
    private var notifiedMissionControl = false
    private var revision = 0
    func start() {
        stop()
        lifecycle = GLSceneObservation.observeChanges { [weak self] type in
            MainActor.assumeIsolated { self?.notice(type) }
        }
    }
    func stop() {
        lifecycle?.invalidate(); lifecycle = nil; revision += 1
        pending = false; notifiedMissionControl = false; missionControl = false
    }
    private func publish(_ active: Bool) {
        if missionControl != active { missionControl = active; onChange?(active) }
    }
    private func notice(_ type: Int32) {
        switch type {
        case 1327, 1328:
            let active = type == 1327
            notifiedMissionControl = active
            if missionControl != active { publish(active) } else { onActivity?() }
        case 1401:
            // Completion is independent of the input device/tool initiating
            // the switch. Do not infer a start from stale cursor images.
            onActivity?()
        default: break
        }
    }
    private let queue = DispatchQueue(label: "Gallery.system-scene", qos: .utility)
    private var pending = false
    private var lastCheck = -Double.infinity
    private var lastPIDCheck = -Double.infinity
    private var dockPIDs = Set<pid_t>()
    private var managerPIDs = Set<pid_t>()
    private(set) var missionControl = false
    private var windowOwners: [CGWindowID: (dock: Bool, checked: Double)] = [:]
    private var pendingOwners = Set<CGWindowID>()
    private var ownerCallbacks: [CGWindowID: [(Bool) -> Void]] = [:]
    func cachedDockWindow(_ id: CGWindowID) -> Bool {
        guard let cached = windowOwners[id], ProcessInfo.processInfo.systemUptime - cached.checked < 2 else { return false }
        return cached.dock
    }
    /// Resolve metadata off the button delivery path. Moving over a window
    /// usually warms this cache before the click; no cursor-position polling.
    func resolveDockWindow(_ id: CGWindowID, completion: ((Bool) -> Void)? = nil) {
        guard id != 0 else { completion?(false); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = windowOwners[id], now - cached.checked < 2 { completion?(cached.dock); return }
        if let completion { ownerCallbacks[id, default: []].append(completion) }
        guard !pendingOwners.contains(id), pendingOwners.count < 2 else {
            if !pendingOwners.contains(id) { ownerCallbacks.removeValue(forKey: id)?.forEach { $0(false) } }
            return
        }
        pendingOwners.insert(id)
        let dock = dockPIDs
        queue.async { [weak self] in
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            let pid = (rows?.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let isDock = pid.map { dock.contains($0) || NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == "com.apple.dock" } ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingOwners.remove(id)
                if self.windowOwners.count >= 64 { self.windowOwners = self.windowOwners.filter { now - $0.value.checked < 2 } }
                if self.windowOwners.count >= 64 { self.windowOwners.removeAll(keepingCapacity: true) }
                self.windowOwners[id] = (isDock, ProcessInfo.processInfo.systemUptime)
                self.ownerCallbacks.removeValue(forKey: id)?.forEach { $0(isDock) }
            }
        }
    }
    #if GALLERY_RUNTIME_CHECKS
    var testOverride: Bool?
    var testTracing = false
    var testRecords: [[String: Any]] = []
    func testNotice(_ type: Int32) {
        if testOverride != nil, type == 1327 || type == 1328 { testOverride = type == 1327 }
        notice(type)
    }
    #endif
    func check(force: Bool = false) {
        #if GALLERY_RUNTIME_CHECKS
        if let active = testOverride {
            if missionControl != active { missionControl = active; onChange?(active) }
            return
        }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending, force || now - lastCheck >= 0.19 else { return }
        lastCheck = now; pending = true
        if now - lastPIDCheck > 2 {
            lastPIDCheck = now
            dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
            managerPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").map(\.processIdentifier))
        }
        let dock = dockPIDs, manager = managerPIDs
        let revision = revision
        #if GALLERY_RUNTIME_CHECKS
        let tracing = testTracing
        #endif
        queue.async { [weak self] in
            #if GALLERY_RUNTIME_CHECKS
            let started = ProcessInfo.processInfo.systemUptime
            let rows = tracing ? (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []) : []
            let shellRows: [[String: Any]] = rows.compactMap { row in
                guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                    dock.contains(pid) || manager.contains(pid) else { return nil }
                return ["owner": dock.contains(pid) ? "Dock" : "WindowManager",
                    "layer": row[kCGWindowLayer as String] ?? -1, "window": row[kCGWindowNumber as String] ?? 0,
                    "bounds": row[kCGWindowBounds as String] ?? [:], "alpha": row[kCGWindowAlpha as String] ?? 0]
            }
            #endif
            let active = GLCursorBridge.missionControlActive(withDockPIDs: dock.map { NSNumber(value: $0) }, managerPIDs: manager.map { NSNumber(value: $0) })
            DispatchQueue.main.async {
                guard let self, self.revision == revision else { return }; self.pending = false
                #if GALLERY_RUNTIME_CHECKS
                if tracing, self.testRecords.count < 1000 {
                    self.testRecords.append(["at": started, "completedAt": ProcessInfo.processInfo.systemUptime,
                        "active": active, "shell": shellRows])
                }
                #endif
                self.publish(active || self.notifiedMissionControl)
            }
        }
    }
}
