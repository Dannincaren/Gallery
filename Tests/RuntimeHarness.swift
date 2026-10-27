import AppKit
import GalleryCore
import GalleryNative

@MainActor
private final class FixtureView: NSView {
    var desiredCursor: NSCursor = .arrow
    override func resetCursorRects() { addCursorRect(bounds, cursor: desiredCursor) }
}

/// Opt-in desktop integration check. The fixture owns a small test window;
/// the controller remains in the background. No mouse/keyboard events are posted.
@main
@MainActor
struct RuntimeHarness {
    static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    static func main() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        _ = NSApplication.shared
        if args.contains("--fixture") { fixture(URL(fileURLWithPath: args.last!)); return }
        NSApp.setActivationPolicy(.accessory)
        let previous = NSWorkspace.shared.frontmostApplication
        let previousPointer = CGEvent(source: nil)?.location
        let directory = URL(fileURLWithPath: args[1])
        let command = directory.appendingPathComponent("fixture.txt")
        let runtime = CursorRuntime(recoveryURL: directory.appendingPathComponent("recovery.plist"))
        var fixtureProcess: Process?
        defer {
            _ = runtime.stop(); fixtureProcess?.terminate(); pump(0.1)
            if let previousPointer { CGWarpMouseCursorPosition(previousPointer) }
            previous?.activate(options: [])
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Quit the user's previous Gallery normally so its own recovery
            // path executes before this isolated test changes cursor resources.
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "io.github.rp0902.Gallery" {
                guard app.terminate() else { throw ThemeError.invalid("请先正常退出旧版 Gallery。") }
                for _ in 0..<100 where !app.isTerminated { pump(0.03) }
                guard app.isTerminated else { throw ThemeError.invalid("旧版 Gallery 未退出，未进行替换测试。") }
            }
            try "arrow".write(to: command, atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: args[0])
            process.environment = ProcessInfo.processInfo.environment.merging(["GALLERY_FIXTURE_THEME": args[2]]) { _, new in new }
            process.arguments = ["--fixture", command.path]; try process.run(); fixtureProcess = process; pump(0.5)
            var theme = try ThemeFiles.load(URL(fileURLWithPath: args[2]))
            theme.idleDelay = 1.2
            try "resize".write(to: command, atomically: true, encoding: .utf8); pump(0.25)
            if let snapshot = GLCursorBridge.currentCursor(), let clip = try? CursorImages.fromCape(snapshot) {
                var expected = CursorMatcher(); expected.add(theme.roles.first { $0.id == "com.apple.cursor.19" }!.clip(.normal)!, role: "horizontal")
                if let standard = GLCursorBridge.standardCursor("com.apple.cursor.19"), let original = try? CursorImages.fromCape(standard) {
                    expected.add(original, role: "horizontal")
                }
                try verify(!expected.match(clip).isEmpty, "测试窗口尚未建立可观察的水平指针，不能验证后台恢复")
            }
            try "arrow".write(to: command, atomically: true, encoding: .utf8); pump(0.25)
            runtime.start(theme); pump(0.4)
            try verify(runtime.enabled, "启用失败：\(runtime.error ?? runtime.status)")
            try verify(!NSApp.isActive, "控制器意外成为前台")
            print("BACKGROUND normal:", runtime.status)
            print("FRONTMOST", NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "fixture", process.processIdentifier)
            try verify(runtime.status.contains("正常选择"), "后台箭头识别失败")
            runtime.testPhysicalDown = true; runtime.injectObserved(.leftMouseDown)
            let press = theme.roles.first { $0.id == "com.apple.coregraphics.Arrow" }!.clip(.press)!
            pump(press.duration + 0.1)
            print("AFTER HOLD", runtime.status, runtime.diagnostics)
            try verify(runtime.status.contains("按住"), "后台按住动画没有触发：\(runtime.status)")
            try verifyRendered(runtime, theme.roles.first { $0.id == "com.apple.coregraphics.Arrow" }!.clip(.hold)!, "后台按住图像")
            runtime.testPhysicalDown = false; runtime.injectObserved(.leftMouseUp); pump(0.02)
            try verify(runtime.status.contains("松手"), "后台松手动画没有触发")
            print("BACKGROUND split click: PASS")
            pump(theme.idleDelay + 0.25)
            try verify(runtime.status.contains("待机"), "后台待机没有触发：\(runtime.status)")
            try verifyRendered(runtime, theme.roles.first { $0.id == "com.apple.coregraphics.Arrow" }!.clip(.idle)!, "后台待机图像")
            runtime.injectObserved(.mouseMoved); pump(0.03)
            try verify(!runtime.overlayVisible, "移动后未退出待机")
            print("BACKGROUND idle and resume: PASS")
            try "resize".write(to: command, atomically: true, encoding: .utf8); pump(0.4)
            if let path = ProcessInfo.processInfo.environment["GALLERY_EXTERNAL_PROBE"] {
                let probe = Process(), pipe = Pipe(); probe.executableURL = URL(fileURLWithPath: path); probe.standardOutput = pipe
                try probe.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
                print("INDEPENDENT PROBE", String(data: output, encoding: .utf8) ?? "")
            }
            try verify(runtime.status.contains("水平调整"), "水平调整识别失败：\(runtime.status)")
            print("BACKGROUND horizontal:", runtime.status)
            try "unknown".write(to: command, atomically: true, encoding: .utf8); pump(0.4)
            try verify(runtime.enabled, "未知光标导致运行层停用")
            try verify(runtime.status.contains("自定义"), "测试光标未进入未知分支：\(runtime.status)")
            try "arrow".write(to: command, atomically: true, encoding: .utf8); pump(0.4)
            try verify(runtime.status.contains("正常选择"), "已知光标未恢复：\(runtime.status)")
            try verify(!runtime.overlayVisible, "常态时未交还系统光标")
            print("BACKGROUND known → unknown → known: PASS")
            try verify(runtime.stop(), "恢复失败")
            print("BACKGROUND restore: PASS")
        } catch {
            print("FAIL:", error.localizedDescription)
            _ = runtime.stop(); fixtureProcess?.terminate()
            if let previousPointer { CGWarpMouseCursorPosition(previousPointer) }
            previous?.activate(options: []); exit(1)
        }
    }
    static func verify(_ value: Bool, _ message: String) throws { if !value { throw ThemeError.invalid(message) } }
    static func verifyRendered(_ runtime: CursorRuntime, _ expected: CursorClip, _ message: String) throws {
        try verify(runtime.overlayVisible, "覆盖层未显示")
        guard let data = runtime.renderedFrame else { throw ThemeError.invalid("没有实际提交到显示层的帧") }
        try verify(expected.frames.contains(data), message + "与显示层中的帧不符")
    }
    static func fixture(_ command: URL) {
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let theme = ProcessInfo.processInfo.environment["GALLERY_FIXTURE_THEME"].flatMap { try? ThemeFiles.load(URL(fileURLWithPath: $0)) }
        func themedCursor(_ id: String) -> NSCursor? {
            guard let clip = theme?.roles.first(where: { $0.id == id })?.clip(.normal), let image = NSImage(data: clip.frames[0]) else { return nil }
            image.size = NSSize(width: clip.width, height: clip.height)
            return NSCursor(image: image, hotSpot: NSPoint(x: clip.hotX, y: clip.hotY))
        }
        let useSystem = ProcessInfo.processInfo.environment["GALLERY_FIXTURE_SYSTEM"] == "1"
        let arrow = useSystem ? .arrow : (themedCursor("com.apple.coregraphics.Arrow") ?? .arrow)
        let horizontal = useSystem ? .resizeLeftRight : (themedCursor("com.apple.cursor.19") ?? .resizeLeftRight)
        let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 360, height: 110),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Gallery 后台兼容性验证 · 自动关闭"
        window.acceptsMouseMovedEvents = true
        let surface = FixtureView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        window.contentView = surface
        let text = NSTextField(labelWithString: "正在验证后台光标与恢复，请稍候…")
        text.frame = NSRect(x: 22, y: 40, width: 320, height: 25); window.contentView?.addSubview(text)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // Cursor ownership follows the window under the pointer, not just the
        // keyboard-focused app. Warp into our own fixture without posting any
        // input events; the controller restores the previous pointer location.
        if let screen = NSScreen.screens.first {
            let point = window.convertPoint(toScreen: NSPoint(x: 10, y: 10))
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.frame.height - point.y))
        }
        var previous = ""
        let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            MainActor.assumeIsolated {
            let value = (try? String(contentsOf: command, encoding: .utf8)) ?? ""
            guard value != previous else { return }; previous = value
            let cursor: NSCursor
            switch value {
            case "arrow": cursor = arrow
            case "resize": cursor = horizontal
            default:
                let image = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { _ in
                    NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 40, height: 40)).fill(); return true
                }
                cursor = NSCursor(image: image, hotSpot: NSPoint(x: 24, y: 24))
            }
            // NSCursor.set optimizes away a repeated arrow even after another
            // connection changed the visible cursor. Force our fixture's role.
            let force = NSSelectorFromString("forceSet")
            surface.desiredCursor = cursor
            window.invalidateCursorRects(for: surface); window.resetCursorRects()
            if cursor.responds(to: force) { _ = cursor.perform(force) }
            else { NSCursor.crosshair.set(); cursor.set() }
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0) { NSApp.postEvent(event, atStart: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common); NSApp.run()
    }
}
