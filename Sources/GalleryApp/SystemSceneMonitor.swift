import AppKit
import GalleryNative

/// Read only the shell's window owner/layer metadata; no window images, AX
/// permissions or keyboard monitoring are needed for Mission Control.
@MainActor
final class SystemSceneMonitor {
    var onChange: ((Bool) -> Void)?
    private let queue = DispatchQueue(label: "Gallery.system-scene", qos: .utility)
    private var pending = false
    private var lastCheck = -Double.infinity
    private var lastPIDCheck = -Double.infinity
    private var dockPIDs = Set<pid_t>()
    private var managerPIDs = Set<pid_t>()
    private(set) var missionControl = false
    #if GALLERY_RUNTIME_CHECKS
    var testOverride: Bool?
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
        queue.async { [weak self] in
            let active = GLCursorBridge.missionControlActive(withDockPIDs: dock.map { NSNumber(value: $0) }, managerPIDs: manager.map { NSNumber(value: $0) })
            DispatchQueue.main.async {
                guard let self else { return }; self.pending = false
                if self.missionControl != active { self.missionControl = active; self.onChange?(active) }
            }
        }
    }
}
