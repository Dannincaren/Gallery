import AppKit
import QuartzCore
import GalleryCore
import GalleryNative

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CursorOverlay {
    private let panel: CursorPanel
    private let layer = CALayer()
    private var hidden = false
    private var key = ""
    private var frameIndex = -1
    private var started = 0.0
    private var lastVisibilityCheck = 0.0
    private var hideConfirmed = true
    private var geometry: CursorClip?
    private var lastScale = -1.0
    private var lastPosition = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    private var lastMovement = 0.0
    private(set) var displayedFrame: Data?
    private(set) var hideRepairs = 0
    var visible: Bool { panel.isVisible && hidden }
    var size: CGSize { panel.frame.size }
    var pointerPosition: CGPoint? {
        guard visible, let geometry else { return nil }
        return CGPoint(x: panel.frame.minX + geometry.hotX, y: panel.frame.minY + geometry.height - geometry.hotY)
    }
    init() {
        panel = CursorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.disableCursorRects(); panel.level = .screenSaver; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(); view.wantsLayer = true; view.layer = layer; panel.contentView = view
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        GLCursorBridge.prepareOverlayWindow(panel.windowNumber)
    }
    func show(_ prepared: PreparedClip, scale: Double, key: String, loops: Bool, now: Double, position: CGPoint) throws {
        let changed = self.key != key
        if changed { self.key = key; frameIndex = -1; started = now; lastVisibilityCheck = 0 }
        let clip = prepared.clip
        let step = max(0, Int((now - started) / clip.frameDuration))
        let index = loops ? step % prepared.frames.count : min(step, prepared.frames.count - 1)
        if position != lastPosition { lastMovement = now }
        let visibilityInterval = now - lastMovement < 0.4 ? 0.05 : 1.0
        if hidden && hideConfirmed && panel.isVisible && index == frameIndex && lastScale == scale && position == lastPosition && now - lastVisibilityCheck < visibilityInterval { return }
        if !hidden {
            // Respect another application's own cursor hiding (for example,
            // typing). A later pointer movement makes it visible again.
            guard GLCursorBridge.cursorVisibility() != 0 else { return }
            try claimHide(); lastVisibilityCheck = 0
        }
        if now - lastVisibilityCheck >= visibilityInterval {
            lastVisibilityCheck = now
            if GLCursorBridge.cursorVisibility() == 1 {
                // Dock and hot zones can reveal the hardware cursor. Release
                // our old ticket before renewing it: never accumulate hides.
                try releaseHide(); try claimHide(); hideRepairs += 1
                if GLCursorBridge.cursorVisibility() == 1 {
                    hideConfirmed = false; panel.orderOut(nil); return // prefer one native cursor
                }
            }
            hideConfirmed = true
        }
        guard hideConfirmed else { return }
        if frameIndex != index {
            let frame = prepared.frames[index]
            layer.contents = frame.image; displayedFrame = frame.data; frameIndex = index
        }
        if changed || lastScale != scale { geometry = clip.scaled(by: scale); lastScale = scale }
        move(to: position)
        lastPosition = position
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func move(to position: CGPoint) {
        guard hidden, let clip = geometry else { return }
        let origin = CGPoint(x: position.x - clip.hotX, y: position.y - (clip.height - clip.hotY))
        if panel.frame.size != CGSize(width: clip.width, height: clip.height) {
            panel.setFrame(NSRect(origin: origin, size: CGSize(width: clip.width, height: clip.height)), display: false)
        } else if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
    private func claimHide() throws {
        guard GLCursorBridge.setBackgroundCursorUpdates(true) == 0 else { throw ThemeError.invalid("无法启用后台光标显示。") }
        GLCursorBridge.setDockCursorOverride(true)
        let result = CGDisplayHideCursor(CGMainDisplayID())
        _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        guard result == .success else { GLCursorBridge.setDockCursorOverride(false); throw ThemeError.invalid("无法隐藏系统指针。") }
        hidden = true
    }
    private func releaseHide() throws {
        guard hidden else { return }
        _ = GLCursorBridge.setBackgroundCursorUpdates(true)
        let result = CGDisplayShowCursor(CGMainDisplayID())
        _ = GLCursorBridge.setBackgroundCursorUpdates(false)
        guard result == .success else { throw ThemeError.invalid("恢复系统指针失败，请再次停用。") }
        hidden = false; GLCursorBridge.setDockCursorOverride(false)
    }
    func hide() throws {
        guard hidden || panel.isVisible else { return }
        try releaseHide()
        panel.orderOut(nil); displayedFrame = nil; key = ""; frameIndex = -1; geometry = nil
        lastScale = -1; lastPosition = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    }
}
