import AppKit
import GalleryCore
import GalleryNative

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keep the system cursor as the semantic source. Replacing that same image
/// from a background connection can conceal later changes requested by other
/// apps. A click-through panel draws Gallery's image while the real pointer is
/// hidden with a balanced, connection-local hide/show pair.
@MainActor
final class CursorOverlay {
    private let panel: CursorPanel
    private let imageView = NSImageView()
    private var hidden = false
    private var images: [Data: NSImage] = [:]
    private var key = ""
    private var started = 0.0
    private(set) var displayedFrame: Data?
    var visible: Bool { panel.isVisible && hidden }
    var size: CGSize { panel.frame.size }
    init() {
        panel = CursorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.disableCursorRects()
        panel.level = .screenSaver; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]; panel.contentView = imageView
        GLCursorBridge.prepareOverlayWindow(panel.windowNumber)
    }
    func show(_ clip: CursorClip, key: String, loops: Bool, now: Double) throws {
        if self.key != key { self.key = key; started = now }
        let step = max(0, Int((now - started) / clip.frameDuration))
        let index = loops ? step % clip.frames.count : min(step, clip.frames.count - 1)
        let data = clip.frames[index]
        if images[data] == nil { images[data] = NSImage(data: data) }
        guard let image = images[data] else { throw ThemeError.invalid("无法显示光标帧。") }
        if !hidden {
            guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { throw ThemeError.invalid("无法启用后台光标显示。") }
            guard CGDisplayHideCursor(CGMainDisplayID()) == .success else {
                _ = GLCursorBridge.setBackgroundCursorUpdates(false)
                throw ThemeError.invalid("无法隐藏系统指针。")
            }
            hidden = true
            // The override is only needed for the hide request. Leaving it
            // enabled can keep Gallery's cached cursor above another app's
            // standard CoreCursor changes.
            _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        }
        if displayedFrame != data { imageView.image = image; displayedFrame = data }
        let position = NSEvent.mouseLocation
        let frame = NSRect(x: position.x - clip.hotX, y: position.y - (clip.height - clip.hotY), width: clip.width, height: clip.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func hide() throws {
        guard hidden || panel.isVisible else { return }
        if hidden {
            _ = GLCursorBridge.setBackgroundCursorUpdates(true)
            guard CGDisplayShowCursor(CGMainDisplayID()) == .success else { throw ThemeError.invalid("恢复系统指针失败，请再次点击停用。") }
            hidden = false
        }
        panel.orderOut(nil); displayedFrame = nil; key = ""
        _ = GLCursorBridge.setBackgroundCursorUpdates(false)
    }
}
