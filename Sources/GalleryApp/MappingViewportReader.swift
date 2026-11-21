import AppKit
import SwiftUI

struct MappingScrollRequest: Equatable {
    let id = UUID()
    let centerY: Double
    let animated: Bool
}

/// Read the actual clip-view bounds. An offset GeometryReader in a SwiftUI
/// scroll document can report the document's coordinate space instead of its
/// viewport, leaving every card below the first screen marked offscreen.
struct MappingViewportReader: NSViewRepresentable {
    @Binding var rect: CGRect
    var target: MappingScrollRequest? = nil
    func makeNSView(context: Context) -> MappingViewportProbe {
        let view = MappingViewportProbe()
        view.changed = { value in DispatchQueue.main.async { rect = value } }
        return view
    }
    func updateNSView(_ nsView: MappingViewportProbe, context: Context) {
        nsView.follow(target)
    }
}

final class MappingViewportProbe: NSView {
    var changed: ((CGRect) -> Void)?
    private weak var observedScroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var lastRect: CGRect?
    private var lastRequest: UUID?
    private var pendingFollow: MappingScrollRequest?
    private var movement: Timer?
    func follow(_ request: MappingScrollRequest?) {
        guard let request, request.id != lastRequest else { return }
        pendingFollow = request
        DispatchQueue.main.async { [weak self] in self?.move(request) }
    }
    private func move(_ request: MappingScrollRequest) {
        guard request.id != lastRequest, pendingFollow?.id == request.id, let scroll = enclosingScrollView, let document = scroll.documentView,
              document.bounds.height > 0, scroll.documentVisibleRect.height > 0 else { return }
        lastRequest = request.id; pendingFollow = nil
        movement?.invalidate(); movement = nil
        let clip = scroll.contentView
        let start = clip.bounds.origin
        let top = min(max(0, request.centerY - scroll.documentVisibleRect.height / 2), max(0, document.bounds.height - scroll.documentVisibleRect.height))
        let targetY = document.isFlipped ? document.bounds.minY + top : document.bounds.maxY - top - scroll.documentVisibleRect.height
        let delta = targetY - start.y
        guard abs(delta) > 1 else { return }
        func step(_ progress: Double) {
            clip.scroll(to: NSPoint(x: start.x, y: start.y + delta * progress)); scroll.reflectScrolledClipView(clip)
        }
        guard request.animated else { step(1); return }
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.6)
            step(t * t * t * (t * (t * 6 - 15) + 10))
            if t == 1 { timer.invalidate(); self?.movement = nil }
        }
        movement = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connectSoon() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connectSoon() }
    private func connectSoon() {
        DispatchQueue.main.async { [weak self] in self?.connect() }
    }
    private func connect() {
        guard let scroll = enclosingScrollView else { return }
        if observedScroll !== scroll {
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
            observedScroll = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in self?.publish() })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.movement?.invalidate(); self?.movement = nil
                if let pending = self?.pendingFollow { self?.lastRequest = pending.id; self?.pendingFollow = nil }
            })
        }
        publish()
    }
    private func publish() {
        guard let scroll = observedScroll, let document = scroll.documentView else { return }
        let visible = scroll.documentVisibleRect
        let top = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
        let value = CGRect(x: 0, y: max(0, top), width: visible.width, height: visible.height)
        if value != lastRect { lastRect = value; changed?(value) }
        if let pendingFollow { move(pendingFollow) }
    }
    deinit { movement?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
