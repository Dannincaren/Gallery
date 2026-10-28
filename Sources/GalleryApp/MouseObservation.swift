import AppKit

@MainActor
final class MouseObservation {
    var onEvent: ((CGEventType) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var active = false
    private(set) var latestTimestamp = 0.0
    private(set) var latestPosition = CGPoint.zero
    private(set) var latestWindowID: CGWindowID = 0
    private(set) var deliveredEvents = 0
    private var displayHeight = 0.0
    var description: String { tap != nil ? "会话鼠标监听" : (active ? "系统鼠标事件监听" : "鼠标计数回退") }
    func start() {
        stop(); displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        if CGPreflightListenEventAccess() { startTap() }
        if !active {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            // Mouse-only monitors do not need keyboard accessibility access.
            // Local monitoring always returns the original event unchanged.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }; return event
            }
            active = globalMonitor != nil && localMonitor != nil
        }
    }
    private func receive(_ event: NSEvent) {
        guard let cg = event.cgEvent else { return }
        latestWindowID = CGWindowID(truncatingIfNeeded: cg.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        deliver(cg.type, timestamp: event.timestamp, position: cg.location)
    }
    private func deliver(_ type: CGEventType, timestamp: Double, position: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        latestTimestamp = timestamp.isFinite && timestamp > 0 && abs(now - timestamp) < 60 ? min(now, timestamp) : now
        latestPosition = CGPoint(x: position.x, y: displayHeight - position.y)
        deliveredEvents += 1; onEvent?(type)
    }
    private func startTap() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                MainActor.assumeIsolated {
                    let observer = Unmanaged<MouseObservation>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = observer.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        observer.active = observer.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
                    } else {
                        observer.latestWindowID = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
                        observer.deliver(type, timestamp: Double(event.timestamp) / 1_000_000_000, position: event.location)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        self.source = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true); active = CGEvent.tapIsEnabled(tap: tap)
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        source = nil; tap = nil; globalMonitor = nil; localMonitor = nil; active = false
    }
}
