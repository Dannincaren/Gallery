import AppKit

@MainActor
final class MouseObservation {
    var onEvent: ((CGEventType) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    func start() {
        guard CGPreflightListenEventAccess() else { return }
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
                    } else { observer.onEvent?(type) }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil; onEvent = nil
    }
}
