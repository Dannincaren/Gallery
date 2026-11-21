import AppKit
import QuartzCore
import GalleryCore
import GalleryNative

/// The system's busy cursor is a separate WindowServer layer. This narrowly
/// scoped fallback never registers or replaces that original resource. Ordinary
/// cursor roles continue to use SystemCursorRenderer without a floating window.
@MainActor
final class WaitCursorOverlay {
    struct Owner {
        let pid: pid_t
        let bounds: CGRect // Quartz desktop coordinates, origin at the top left.
    }
    struct IO {
        var visibility: () -> Int32 = { GLCursorBridge.cursorVisibility() }
        var background: (Bool) -> Int32 = { GLCursorBridge.setBackgroundCursorUpdates($0) }
        var hide: () -> CGError = { CGDisplayHideCursor(CGMainDisplayID()) }
        var show: () -> CGError = { CGDisplayShowCursor(CGMainDisplayID()) }
        var position: () -> CGPoint = { NSEvent.mouseLocation }
        var refreshRate: (CGPoint) -> Int = { point in
            NSScreen.screens.first(where: { $0.frame.contains(point) })?.maximumFramesPerSecond ?? 60
        }
        var moveWindow: (Int32, CGPoint) -> Bool = { GLCursorBridge.moveOverlayWindow($0, origin: $1) == 0 }
        var owner: (CGWindowID) -> Owner? = { id in
            guard id != 0,
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                  let row = rows.first,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return Owner(pid: pid.int32Value, bounds: bounds)
        }
    }
    var willActivate: (() -> Void)?
    var onChange: ((Bool) -> Void)?
    private let io: IO
    private let detectionTimeout: Double
    private var observation: GLBusyObservation?
    private var query: ((pid_t) -> Bool)?
    private var watchdog: Timer?
    private var moveTask: DispatchWorkItem?
    private var lastMove = -Double.infinity
    private var windowID: CGWindowID = 0
    private var owner: Owner?
    private var owners: [CGWindowID: (owner: Owner, readAt: Double)] = [:]
    private var ownerReadAt = -Double.infinity
    private var waitingForVisibility = false
    private var failedWindow: CGWindowID?
    private var suspended = false
    private var hideTicket = false
    private var running = false
    private var panel: CursorOverlayPanel?
    private var imageLayer: CALayer?
    private var origin: CGPoint?
    private var positionedPointer: CGPoint?
    private var placementNeedsAppKit = true
    private var geometry: CursorRasterGeometry?
    private struct Playback: Equatable {
        let first: ObjectIdentifier
        let count: Int, motion: Motion, started: Double
    }
    private var playback: Playback?
    private var initial: (clip: PreparedClip, scale: Double, smooth: Bool)?
    private(set) var active = false
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    #if GALLERY_WAIT_DIAGNOSTICS
    var diagnostic: ((String, Int32) -> Void)?
    #endif
    #if GALLERY_RUNTIME_CHECKS
    private(set) var positionChanges = 0
    private(set) var playbackChanges = 0
    private(set) var queries = 0
    private(set) var watchdogStarts = 0
    private(set) var directMoves = 0
    var testHasWatchdog: Bool { watchdog != nil }
    var testPanelFrame: CGRect? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, testWindowID) as? [[String: Any]],
              let dictionary = rows.first?[kCGWindowBounds as String] as? NSDictionary,
              var frame = CGRect(dictionaryRepresentation: dictionary) else { return nil }
        frame.origin.y = CGDisplayBounds(CGMainDisplayID()).height - frame.maxY
        return frame
    }
    var testGeometry: CursorRasterGeometry? { geometry }
    var testWindowID: CGWindowID { CGWindowID(panel?.windowNumber ?? 0) }
    #endif

    init(io: IO = IO(), detectionTimeout: Double = 2) {
        self.io = io; self.detectionTimeout = min(5, max(1, detectionTimeout.isFinite ? detectionTimeout : 2))
    }

    @discardableResult
    func start(_ clip: PreparedClip, scale: Double, smooth: Bool) -> Bool {
        stop()
        initial = (clip, scale, smooth)
        prepare(clip, scale: scale, smooth: smooth)
        guard let observer = GLBusyObservation.observeChanges({ [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }, timeout: detectionTimeout) else { stop(); return false }
        observation = observer
        query = { [weak observer] in observer?.isUnresponsive($0) == true }
        running = true
        return true
    }
    #if GALLERY_RUNTIME_CHECKS
    func testStart(_ clip: PreparedClip, scale: Double = 1, smooth: Bool = true,
                   query: @escaping (pid_t) -> Bool) {
        stop(); initial = (clip, scale, smooth); prepare(clip, scale: scale, smooth: smooth)
        self.query = query; running = true
    }
    #endif

    /// Reuse Gallery's existing mouse-only observer. At rest there is no follow
    /// timer; motion changes the window origin at most once per display frame.
    func pointerChanged(window id: CGWindowID) {
        guard running else { return }
        let changed = windowID != id
        windowID = id
        if id == 0 { owners.removeAll(keepingCapacity: true) }
        if changed {
            failedWindow = nil
            if let cached = owners[id], now - cached.readAt < 2 {
                owner = cached.owner; ownerReadAt = cached.readAt
            } else { owner = nil; ownerReadAt = -.infinity }
            refresh()
        }
        else if waitingForVisibility && now - ownerReadAt >= 0.2 { refresh() }
        guard active else { return }
        guard io.visibility() == 0 else { abandonVisibleOverlay(); return }
        let point = io.position()
        guard point != positionedPointer else { return }
        // A leading update does not wait for another main-queue turn. Follow
        // the current display up to 120 Hz, coalescing only the remaining
        // events in that frame rather than imposing a fixed 60 Hz delay.
        let interval = 1.0 / Double(max(60, min(120, io.refreshRate(point))))
        let remaining = interval - (now - lastMove)
        if remaining <= 0 {
            moveTask?.cancel(); moveTask = nil
            move(); lastMove = now; return
        }
        guard moveTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.moveTask = nil
            guard self.active else { return }
            guard self.io.visibility() == 0 else { self.abandonVisibleOverlay(); return }
            self.move(); self.lastMove = self.now
        }
        moveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: task)
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if value { deactivate() } else { refresh() }
    }
    func setScale(_ value: Double) {
        guard value.isFinite else { return }
        initial?.scale = value
    }

    func refresh() {
        guard running, !suspended, let query else { deactivate(); return }
        // Refresh inexpensive owner metadata only on window changes or while
        // an active busy cursor is being checked. Never capture window images.
        let point = io.position()
        let quartz = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        if owner == nil || (active && now - ownerReadAt >= 0.2) || owner?.bounds.contains(quartz) == false {
            owner = io.owner(windowID); ownerReadAt = now
            if let owner {
                if owners.count >= 64 { owners = owners.filter { now - $0.value.readAt < 2 } }
                if owners.count >= 64 { owners.removeAll(keepingCapacity: true) }
                owners[windowID] = (owner, now)
            }
        }
        guard let owner, owner.pid != ProcessInfo.processInfo.processIdentifier, owner.bounds.contains(quartz) else {
            waitingForVisibility = false; deactivate(); return
        }
        #if GALLERY_RUNTIME_CHECKS
        queries += 1
        #endif
        guard query(owner.pid) else { waitingForVisibility = false; failedWindow = nil; deactivate(); return }
        if active {
            if io.visibility() != 0 { abandonVisibleOverlay() }
            return
        }
        guard failedWindow != windowID else { return }
        guard io.visibility() == 1 else { waitingForVisibility = true; return }
        waitingForVisibility = false
        guard let initial else { return }
        guard panel != nil, io.background(true) == 0 else { return }
        guard io.hide() == .success else { _ = io.background(false); return }
        hideTicket = true
        #if GALLERY_WAIT_DIAGNOSTICS
        diagnostic?("hidden-before-handover", io.visibility())
        #endif
        willActivate?()
        #if GALLERY_WAIT_DIAGNOSTICS
        diagnostic?("after-cleanup-before-reacquire", io.visibility())
        #endif
        // Ordinary rendering and this overlay use the same WS connection.
        // passThrough releases the renderer's background flag. Reacquire it
        // after that cleanup without issuing a second hide or hide ticket.
        guard io.background(true) == 0, io.visibility() == 0 else {
            abandonVisibleOverlay(); return
        }
        #if GALLERY_WAIT_DIAGNOSTICS
        diagnostic?("hidden-after-handover", io.visibility())
        #endif
        active = true
        present(initial.clip, motion: .normal, scale: initial.scale, smooth: initial.smooth, started: now)
        move(); lastMove = now; panel?.orderFrontRegardless()
        // Only an active fallback has a slow safety check. Normal operation
        // relies entirely on two WindowServer edges and existing mouse events.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        #if GALLERY_RUNTIME_CHECKS
        watchdogStarts += 1
        #endif
        onChange?(true)
    }

    private func abandonVisibleOverlay() {
        #if GALLERY_WAIT_DIAGNOSTICS
        diagnostic?("native-visibility-lost", io.visibility())
        #endif
        let failed = windowID
        deactivate()
        // Do not pile up hide calls to fight a system visibility change.
        // Keep the original cursor for this busy visit; re-entry or a healthy
        // responsiveness edge permits a fresh, balanced attempt.
        failedWindow = failed; waitingForVisibility = false
    }

    private func prepare(_ clip: PreparedClip, scale: Double, smooth: Bool) {
        // Allocate the panel and fill its backing before the pointer ever
        // enters a busy window. Re-entry has no allocation or image decoding
        // between receiving the mouse event and hiding the system busy layer.
        present(clip, motion: .normal, scale: scale, smooth: smooth, started: now)
        imageLayer?.removeAnimation(forKey: "cursor"); playback = nil
    }

    /// Core Animation plays the already decoded frames. There is no per-frame
    /// SwiftUI redraw, PNG decoding or 60 Hz app timer for a looping busy clip.
    func present(_ prepared: PreparedClip, motion: Motion, scale: Double, smooth: Bool, started: Double) {
        guard let first = prepared.frames.first else { return }
        if panel == nil {
            let window = CursorOverlayPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
            window.isRestorable = false; window.animationBehavior = .none; window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSView(frame: .zero); view.wantsLayer = true
            let layer = CALayer(); view.layer = layer; window.contentView = view
            panel = window; imageLayer = layer
        }
        let grid = CursorRasterGeometry(prepared.clip, scale: scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if geometry != grid {
            geometry = grid; origin = nil; placementNeedsAppKit = true
            panel?.setContentSize(CGSize(width: grid.width, height: grid.height))
        }
        imageLayer?.contentsGravity = .resize
        imageLayer?.magnificationFilter = smooth ? .linear : .nearest
        imageLayer?.minificationFilter = smooth ? .linear : .nearest
        let key = Playback(first: ObjectIdentifier(first.image), count: prepared.frames.count, motion: motion, started: started)
        if playback != key {
            playback = key
            imageLayer?.removeAnimation(forKey: "cursor")
            imageLayer?.contents = motion.loops ? first.image : prepared.frames.last?.image
            if prepared.uniqueImages.count > 1 {
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.calculationMode = .discrete
                animation.values = prepared.frames.map(\.image)
                animation.keyTimes = prepared.frames.indices.map { NSNumber(value: Double($0) / Double(prepared.frames.count)) }
                animation.duration = prepared.clip.duration
                animation.repeatCount = motion.loops ? .infinity : 0
                animation.timeOffset = max(0, now - started)
                animation.isRemovedOnCompletion = !motion.loops
                imageLayer?.add(animation, forKey: "cursor")
            }
            #if GALLERY_RUNTIME_CHECKS
            playbackChanges += 1
            #endif
        }
        CATransaction.commit()
        if active { move() }
    }
    private func move() {
        guard let panel, let grid = geometry else { return }
        let point = io.position()
        positionedPointer = point
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        let factor = screen?.backingScaleFactor ?? 2
        let requested = CGPoint(x: ((point.x - grid.hotX) * factor).rounded() / factor,
            y: ((point.y - grid.height + grid.hotY) * factor).rounded() / factor)
        guard origin != requested || !panel.isVisible else { return }
        origin = requested
        // AppKit's frame setter does substantial bookkeeping for an ordinary
        // window. While visible, move this owned borderless panel directly;
        // use AppKit for initial placement, resizing and the safe fallback.
        let quartz = CGPoint(x: requested.x, y: CGDisplayBounds(CGMainDisplayID()).height - requested.y - grid.height)
        if placementNeedsAppKit || !panel.isVisible {
            // Keep AppKit's cached frame consistent with a resize/re-entry;
            // otherwise its later layout commit can undo a direct origin.
            panel.setFrameOrigin(requested); placementNeedsAppKit = false
            _ = io.moveWindow(Int32(panel.windowNumber), quartz)
        } else if io.moveWindow(Int32(panel.windowNumber), quartz) {
            #if GALLERY_RUNTIME_CHECKS
            directMoves += 1
            #endif
        } else { panel.setFrameOrigin(requested) }
        #if GALLERY_RUNTIME_CHECKS
        positionChanges += 1
        #endif
    }
    private func deactivate() {
        moveTask?.cancel(); moveTask = nil
        watchdog?.invalidate(); watchdog = nil
        let wasActive = active; active = false
        panel?.orderOut(nil); imageLayer?.removeAnimation(forKey: "cursor"); playback = nil
        if hideTicket {
            // Balance only Gallery's own successful hide. An app's own cursor
            // hiding (typing/games) is never cleared with extra show calls.
            _ = io.background(true); _ = io.show(); hideTicket = false; _ = io.background(false)
        }
        #if GALLERY_WAIT_DIAGNOSTICS
        if wasActive { diagnostic?("deactivated", io.visibility()) }
        #endif
        if wasActive { onChange?(false) }
    }
    func stop() {
        running = false; observation?.invalidate(); observation = nil; query = nil
        deactivate(); panel?.close(); panel = nil; imageLayer = nil
        initial = nil; geometry = nil; origin = nil; positionedPointer = nil; owner = nil; windowID = 0
        placementNeedsAppKit = true
        owners.removeAll(keepingCapacity: true)
        ownerReadAt = -.infinity; waitingForVisibility = false; failedWindow = nil; suspended = false
    }
}

private final class CursorOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
