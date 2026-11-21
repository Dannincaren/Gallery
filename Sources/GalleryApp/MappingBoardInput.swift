import AppKit
import SwiftUI

struct MappingInputLine: Equatable {
    let id: String
    let start: CGPoint
    let end: CGPoint
    var path: CGPath {
        let path = CGMutablePath(); path.move(to: start)
        let bend = (end.x - start.x) * 0.45
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return path
    }
}

/// No single-tap recognizer waits for a possible double tap. AppKit supplies
/// the actual click count; only consecutive clicks on the same line unlink it.
struct MappingLineClicks {
    enum Action: Equatable { case select(String?), disconnect(String) }
    private var lastID: String?
    private var lastPoint = CGPoint.zero
    private var lastTime = -Double.infinity
    mutating func down(line: String?, count: Int, point: CGPoint, time: Double, interval: Double) -> Action {
        let double = line != nil && line == lastID && count == 2 && time - lastTime <= interval
            && hypot(point.x - lastPoint.x, point.y - lastPoint.y) <= 6
        lastID = double ? nil : line; lastTime = time; lastPoint = point
        return double ? .disconnect(line!) : .select(line)
    }
}

struct MappingBoardInput: NSViewRepresentable {
    let cards: [CGRect]
    let lines: [MappingInputLine]
    let selected: String?
    let action: (MappingLineClicks.Action) -> Void
    func makeNSView(context: Context) -> MappingBoardInputView {
        let view = MappingBoardInputView(); view.setAccessibilityElement(false); return view
    }
    func updateNSView(_ view: MappingBoardInputView, context: Context) {
        view.configure(cards: cards, lines: lines, selected: selected, action: action)
    }
}

final class MappingBoardInputView: NSView {
    override var isFlipped: Bool { true }
    private var cards: [CGRect] = []
    private var movingCards: [CGRect] = []
    private var movingUntil = 0.0
    private var lines: [MappingInputLine] = []
    private var clicks = MappingLineClicks()
    private var action: ((MappingLineClicks.Action) -> Void)?
    private var monitor: Any?
    func configure(cards: [CGRect], lines: [MappingInputLine], selected: String?, action: @escaping (MappingLineClicks.Action) -> Void) {
        if self.cards != cards {
            // Let native buttons keep their clicks throughout the short layout
            // animation, including the space between their old and new frames.
            movingCards = self.cards.count == cards.count ? zip(self.cards, cards).map { $0.union($1) } : self.cards
            movingUntil = ProcessInfo.processInfo.systemUptime + 0.4
            self.cards = cards
        }
        self.lines = lines.filter { $0.id == selected } + lines.reversed().filter { $0.id != selected }
        self.action = action
    }
    // A transparent representable must never steal the native SwiftUI
    // buttons' mouse or accessibility actions. Its local window monitor handles
    // only the gaps and lines, before a tap recognizer can delay selection.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func consumesMouseDown(at point: CGPoint) -> Bool {
        bounds.contains(point) && !cards.contains { $0.contains(point) }
            && !(ProcessInfo.processInfo.systemUptime < movingUntil && movingCards.contains { $0.contains(point) })
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if let clip = self.enclosingScrollView?.contentView,
               !clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.consumesMouseDown(at: point) else { return event }
            if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            let line = self.lines.first { $0.path.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point) }
            self.action?(self.clicks.down(line: line?.id, count: event.clickCount, point: point,
                time: event.timestamp, interval: NSEvent.doubleClickInterval))
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
