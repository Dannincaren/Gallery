import SwiftUI

struct EditorVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = { value in DispatchQueue.main.async { visible = value } }
        return view
    }
    func updateNSView(_ nsView: VisibilityView, context: Context) {}
}

final class VisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        guard let window else { changed?(false); return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] note in
                self?.changed?(note.name != NSWindow.willCloseNotification && (window?.occlusionState.contains(.visible) ?? false))
            })
        }
        changed?(window.occlusionState.contains(.visible))
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
