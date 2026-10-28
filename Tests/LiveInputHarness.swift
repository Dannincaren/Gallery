import AppKit
import Darwin
import GalleryCore

@MainActor
final class InputSurface: NSView {
    var events: [[String: Any]] = []
    var output: URL!
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func resetCursorRects() {
        let third = bounds.width / 3
        addCursorRect(NSRect(x: 0, y: 0, width: third, height: bounds.height), cursor: .arrow)
        addCursorRect(NSRect(x: third, y: 0, width: third, height: bounds.height), cursor: .iBeam)
        addCursorRect(NSRect(x: third * 2, y: 0, width: third, height: bounds.height), cursor: .resizeLeftRight)
    }
    func record(_ event: NSEvent, edge: String) {
        events.append(["edge": edge, "at": event.timestamp])
        if events.count > 100 { events.removeFirst() }
        try? JSONSerialization.data(withJSONObject: events).write(to: output, options: .atomic)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { record(event, edge: "down") }
    override func mouseUp(with event: NSEvent) { record(event, edge: "up") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let third = bounds.width / 3
        for i in 0..<3 {
            let x = CGFloat(i) * third
            NSColor.separatorColor.setStroke(); NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: bounds.height))
            (["箭头：单击 / 双击 / 按住", "文字选择", "水平调整"][i] as NSString)
                .draw(at: NSPoint(x: x + 14, y: 135), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        }
        ("安全测试区域：点击只记录时序，不执行其他操作。\n已记录 \(events.count) 个按下/松手事件。" as NSString)
            .draw(at: NSPoint(x: 14, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

@MainActor
final class LiveDelegate: NSObject, NSApplicationDelegate {
    var runtime: CursorRuntime?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        runtime?.stop() == false ? .terminateCancel : .terminateNow
    }
}

@main @MainActor
struct LiveInputHarness {
    static func inputChecks(_ runtime: CursorRuntime, root: URL) throws {
        let arrow = "com.apple.coregraphics.Arrow"
        runtime.testRecognitionSuspended = true
        defer { runtime.testRecognitionSuspended = false; runtime.testPhysicalDown = nil }
        runtime.testPhysicalDown = true
        runtime.testIdentify([arrow])
        let timestamp = ProcessInfo.processInfo.systemUptime - 0.01
        runtime.injectObserved(.leftMouseDown, timestamp: timestamp)
        let epoch = runtime.testMotionStartedAt
        runtime.testIdentify(["com.apple.cursor.0"])
        guard runtime.testMotion == .press, runtime.testMotionStartedAt == epoch else { throw ThemeError.invalid("别名变化重启了点按") }
        runtime.testIdentify([arrow, "com.apple.cursor.0"])
        guard runtime.testMotionStartedAt == epoch else { throw ThemeError.invalid("别名列表重启了点按") }
        runtime.testPhysicalDown = false
        runtime.injectObserved(.leftMouseUp)
        guard runtime.testMotion != .hold && runtime.testMotion != .press else { throw ThemeError.invalid("松手后仍然播放按住") }
        // A down callback that arrives after the physical release must never
        // submit a hold frame, even before the queued up callback arrives.
        runtime.injectObserved(.leftMouseDown)
        RunLoop.main.run(until: Date().addingTimeInterval(0.012))
        runtime.testIdentify([arrow])
        guard runtime.testMotion != .hold && runtime.testMotion != .press else { throw ThemeError.invalid("过时的按下事件盖过物理松手") }
        runtime.testPhysicalDown = nil
        guard try runtime.testRegisteredShellImage(at: root) else { throw ThemeError.invalid("系统光标通道未选择主题常态图像") }
        try "PASS alias continuity; mouse-up preempts queued down; no late hold; registered shell cursor".write(to: root.appendingPathComponent("regressions.txt"), atomically: true, encoding: .utf8)
    }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let configURL = Bundle.main.resourceURL!.appendingPathComponent("config.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: String]
        let root = URL(fileURLWithPath: config["directory"]!)
        let fixture = Bundle.main.bundleIdentifier!.hasSuffix("Fixture")
        NSApp.setActivationPolicy(fixture ? .regular : .accessory)
        NSApp.finishLaunching()
        let delegate = LiveDelegate(); NSApp.delegate = delegate
        var runtime: CursorRuntime?, window: NSWindow?
        if fixture {
            let surface = InputSurface(frame: NSRect(x: 0, y: 0, width: 630, height: 210))
            surface.output = root.appendingPathComponent("fixture-events.json")
            window = NSWindow(contentRect: NSRect(x: 280, y: 280, width: 630, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window!.title = "Gallery 鼠标响应验证"; window!.contentView = surface; window!.acceptsMouseMovedEvents = true
            window!.makeKeyAndOrderFront(nil)
        } else {
            var theme = try ThemeFiles.load(URL(fileURLWithPath: config["theme"]!)); theme.idleEnabled = false
            runtime = CursorRuntime(recoveryURL: root.appendingPathComponent("recovery.plist"))
            delegate.runtime = runtime
            if runtime!.hasRecovery { runtime!.recover() }
            runtime!.start(theme)
            print("START", runtime!.enabled, runtime!.error ?? runtime!.status)
            guard runtime!.enabled else { throw ThemeError.invalid(runtime!.error ?? "启用失败") }
            do { try inputChecks(runtime!, root: root) }
            catch {
                _ = runtime!.stop()
                print("FAIL", error.localizedDescription)
                exit(1)
            }
            if CommandLine.arguments.contains("--checks-only") { _ = runtime!.stop(); return }
        }
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "退出验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; NSApp.mainMenu = menu
        var baselineCPU = cpu(), baselineTime = ProcessInfo.processInfo.systemUptime
        var history: [[String: Any]] = [], lastScene: Bool?
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let command = (try? String(contentsOf: root.appendingPathComponent("command.txt"), encoding: .utf8)) ?? ""
                if command == "stop" { if runtime?.stop() != false { NSApp.terminate(nil) }; return }
                if command == "measure" {
                    baselineCPU = cpu(); baselineTime = ProcessInfo.processInfo.systemUptime
                    try? "running".write(to: root.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)
                }
                if let runtime {
                    var state = runtime.testStats
                    state["cpuPercent"] = (cpu() - baselineCPU) / max(0.001, ProcessInfo.processInfo.systemUptime - baselineTime) * 100
                    state["at"] = ProcessInfo.processInfo.systemUptime
                    if lastScene != runtime.testMissionControl {
                        lastScene = runtime.testMissionControl; history.append(state)
                        try? JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("scene-history.json"), options: .atomic)
                    }
                    try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("probe-state.json"), options: .atomic)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        NSApp.run()
        withExtendedLifetime((delegate, runtime, window, timer)) {}
    }
}
