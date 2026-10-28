import AppKit
import Darwin
import GalleryCore
import GalleryNative

/// Own-process checks: no mouse warps, OS input injection or app switching.
@main @MainActor
struct RuntimeHarness {
    static func verify(_ value: Bool, _ reason: String) throws { if !value { throw ThemeError.invalid(reason) } }
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let renderer = SystemCursorRenderer(), initial = GLCursorBridge.currentCursor()
        var runtime: CursorRuntime?
        defer { _ = runtime?.stop(); renderer.stop(restoring: initial) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try [NSColor.red, .green, .blue].map { color -> Data in
                let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                return try CursorImages.png(context.makeImage()!)
            }
            let clip = CursorClip(frames: data, frameDuration: 0.1, hotX: 3, hotY: 3)
            let prepared = try PreparedCursors(roles: [CursorRole(id: "test", name: "Test", clips: ["normal": clip])]).clip(role: "test", motion: .normal)!
            let start = ProcessInfo.processInfo.systemUptime
            for i in 0..<3 {
                renderer.present(prepared, role: "test", motion: .normal, scale: 1, started: start, now: start + Double(i) * 0.1 + 0.001)
                let until = ProcessInfo.processInfo.systemUptime + 0.1
                var displayed = false
                repeat {
                    if let snapshot = GLCursorBridge.currentSnapshot(),
                       let color = NSBitmapImageRep(cgImage: snapshot.image).colorAt(x: snapshot.image.width / 2, y: snapshot.image.height / 2)?.usingColorSpace(.deviceRGB),
                       [color.redComponent, color.greenComponent, color.blueComponent][i] > 0.8 { displayed = true; break }
                    pump(0.002)
                } while ProcessInfo.processInfo.systemUptime < until
                try verify(displayed, "系统通道没有显示第 \(i) 帧")
                try verify(GLCursorBridge.cursorVisibility() != 0, "更新图像隐藏了系统光标")
            }
            for i in 0..<300 {
                renderer.present(prepared, role: i % 2 == 0 ? "arrow" : "link", motion: .normal,
                                 scale: i % 2 == 0 ? 1 : 1.5, started: start, now: start)
                try verify(GLCursorBridge.cursorVisibility() != 0, "快速角色切换导致光标消失")
                try verify(renderer.size.width == (i % 2 == 0 ? 32 : 48), "尺寸缓存串到其他角色")
            }
            let repeatedClip = CursorClip(frames: [data[0], data[0], data[2]], frameDuration: 0.1)
            let repeated = try PreparedCursors(roles: [CursorRole(id: "repeat", name: "Repeat", clips: ["normal": repeatedClip])]).clip(role: "repeat", motion: .normal)!
            renderer.present(repeated, role: "repeat", motion: .normal, scale: 1, started: start, now: start)
            let submitted = renderer.submissions
            renderer.present(repeated, role: "repeat", motion: .normal, scale: 1, started: start, now: start + 0.11)
            try verify(renderer.submissions == submitted, "重复帧仍重复提交")
            try verify(abs((renderer.nextFrameDeadline ?? 0) - (start + 0.2)) < 0.001, "跳过重复帧改变了停留时长")
            renderer.stop(restoring: initial)
            print("PASS native frames, 300 switches, visibility and independent geometry")
            let foreground = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(data[2]), size: NSSize(width: 32, height: 32)), hotSpot: .zero)
            _ = GLCursorBridge.present(foreground); pump(0.01)
            let foregroundSeed = GLCursorBridge.cursorSeed()
            renderer.testDelayedSeed = true
            renderer.present(prepared, role: "test", motion: .normal, scale: 1, started: start, now: start)
            try verify(!renderer.owns(seed: foregroundSeed), "延迟返回的旧前台编号被误记成 Gallery 所有")
            guard let pending = renderer.pendingImage else { throw ThemeError.invalid("延迟提交没有等待图像确认") }
            pump(0.01)
            var confirmed = false
            let acknowledgment = CursorRecognition(matcher: CursorMatcher())
            acknowledgment.probe(pendingImage: pending.fingerprint) { seed, _, ownImage in
                DispatchQueue.main.async { confirmed = ownImage && renderer.confirmPending(seed: seed, revision: pending.revision) }
            }
            pump(0.1)
            try verify(confirmed && renderer.owns(seed: GLCursorBridge.cursorSeed()), "实际图像确认后仍无法识别自己的提交")
            renderer.testDelayedSeed = false; renderer.stop(restoring: initial)
            print("PASS delayed seed never claims foreground; actual image acknowledges submission")
            let originalArrowClip = try CursorImages.fromCape(GLCursorBridge.standardCursor("com.apple.coregraphics.Arrow")!)
            let originalArrow = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(originalArrowClip.frames[0]),
                size: NSSize(width: originalArrowClip.width, height: originalArrowClip.height)),
                hotSpot: NSPoint(x: originalArrowClip.hotX, y: originalArrowClip.hotY))
            var theme = try ThemeFiles.load(URL(fileURLWithPath: CommandLine.arguments[2])); theme.idleEnabled = false
            let engine = CursorRuntime(recoveryURL: root.appendingPathComponent("recovery.plist")); runtime = engine
            if engine.hasRecovery { engine.recover() }; engine.start(theme)
            try verify(engine.enabled, engine.error ?? "启用失败"); engine.testRecognitionSuspended = true
            let arrow = "com.apple.coregraphics.Arrow", link = "com.apple.cursor.13", horizontal = "com.apple.cursor.19", vertical = "com.apple.cursor.23"
            for id in [arrow, link, horizontal, vertical] {
                engine.testIdentify([id]); try verify(engine.renderedFrame != nil, "角色没有提交缓存图像：\(id)")
            }
            for id in [horizontal, vertical, "com.apple.cursor.35"] {
                let nativeClip = theme.roles.first(where: { $0.id == id })!.clip(.normal)!
                let native = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(nativeClip.frames[0]),
                    size: NSSize(width: nativeClip.width, height: nativeClip.height)),
                    hotSpot: NSPoint(x: nativeClip.hotX, y: nativeClip.hotY))
                _ = GLCursorBridge.present(native)
                let before = engine.testSubmissions
                engine.testIdentify([id], applied: [id])
                try verify(engine.testFrameDeadline == nil && engine.testSubmissions == before,
                           "已注册的调整常态仍被逐帧接管：\(id)")
                pump(0.12)
                try verify(engine.testSubmissions == before, "调整区域内持续重设光标")
                _ = GLCursorBridge.present(originalArrow)
                engine.testIdentify([arrow])
                try verify(engine.testRole.map(CursorCatalog.family) == CursorCatalog.family(arrow),
                           "离开注册调整区域后需要额外点击才恢复")
            }
            print("PASS registered resize playback yields to foreground without animation submissions")
            engine.testIdentify([arrow])
            let foreign = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(data[2]), size: NSSize(width: 32, height: 32)), hotSpot: .zero)
            let obsoleteSeed = GLCursorBridge.present(foreign)
            engine.testIdentify([arrow])
            pump(0.01)
            engine.testDeliverObservation(seed: obsoleteSeed, roles: [horizontal])
            try verify(engine.testRole.map(CursorCatalog.family) == CursorCatalog.family(arrow),
                       "迟到的调整角色观察覆盖了已更新的光标")
            print("PASS obsolete resize observation cannot override a newer cursor")
            engine.testIdentify([link]); engine.setRoleScale(1.7, for: horizontal)
            try verify(engine.testRoleScale(horizontal) == 1.7 && engine.testRoleScale(link) == 1 && engine.testRoleScale(vertical) == 1, "独立大小在运行层串联")
            engine.setRoleIdleDelay(23, for: arrow); engine.testIdentify([arrow])
            try verify(engine.testEffectiveIdleDelay == 23, "运行层未使用角色待机时间")
            engine.testIdentify([link]); try verify(engine.testEffectiveIdleDelay == theme.idleDelay, "待机时间串到另一角色")
            engine.setRoleIdleDelay(nil, for: arrow)
            let movementTicks = engine.tickCount
            for _ in 0..<1000 { engine.injectObserved(.mouseMoved) }
            try verify(engine.tickCount - movementTicks < 5, "纯移动仍触发高频渲染")
            engine.testPhysicalDown = true; engine.testIdentify([arrow]); engine.injectObserved(.leftMouseDown)
            let epoch = engine.testMotionStartedAt; engine.testIdentify(["com.apple.cursor.0"])
            try verify(engine.testMotionStartedAt == epoch && engine.testMotion == .press, "别名切换重播点按")
            engine.testPhysicalDown = false; engine.injectObserved(.leftMouseUp)
            try verify(engine.testMotion == .release, "快速松手未立即抢占按住"); engine.testPhysicalDown = nil
            var testedFamilies = Set<String>()
            for role in theme.roles where !CursorCatalog.assetOnly(role.id) && role.clip(.hold) != nil {
                guard testedFamilies.insert(CursorCatalog.family(role.id)).inserted else { continue }
                engine.testIdentify([role.id]); engine.testPhysicalDown = true
                let downAt = ProcessInfo.processInfo.systemUptime
                engine.injectObserved(.leftMouseDown, timestamp: downAt)
                pump((role.clip(.press)?.duration ?? 0) + 0.02)
                try verify(engine.testMotion == .hold, "拆分模式无法保持按住：\(role.id)")
                let heldAt = engine.testMotionStartedAt
                engine.testIdentify(["com.apple.cursor.5"]); engine.testIdentify([role.id])
                try verify(engine.testMotion == .hold && engine.testMotionStartedAt == heldAt, "拖放/聚焦切换重播按住")
                engine.testPhysicalDown = false
                engine.injectObserved(.leftMouseUp)
                let releasedAt = engine.testMotionStartedAt
                engine.testIdentify(["com.apple.cursor.5"]); engine.testIdentify([role.id])
                engine.injectObserved(.leftMouseDown, timestamp: downAt + 0.00001)
                engine.injectObserved(.leftMouseUp)
                try verify(engine.testMotion == .release && engine.testMotionStartedAt == releasedAt,
                           "拖放/焦点变化或迟到事件重复播放松手：\(role.id)")
                pump(0.005)
            }
            engine.testPhysicalDown = nil
            print("PASS \(testedFamilies.count) role families hold and single release across drag/focus changes")
            pump(0.25); engine.testIdentify([arrow])
            let beforeTicks = engine.tickCount, beforeCPU = cpu(), beforeTime = ProcessInfo.processInfo.systemUptime
            pump(4)
            print("PERF staticCPU=\((cpu() - beforeCPU) / (ProcessInfo.processInfo.systemUptime - beforeTime) * 100) ticks=\(engine.tickCount - beforeTicks)")
            try verify(engine.tickCount - beforeTicks < 60, "静态指针仍在高频唤醒")
            engine.testIdentify(["com.apple.coregraphics.IBeam"])
            let animationCPU = cpu(), animationTime = ProcessInfo.processInfo.systemUptime
            pump(3)
            print("PERF animatedCPU=\((cpu() - animationCPU) / (ProcessInfo.processInfo.systemUptime - animationTime) * 100)")
            engine.testScene(true); pump(0.03)
            try verify(GLCursorBridge.cursorVisibility() != 0 && engine.testMissionControl, "调度中心路径丢失光标")
            engine.testScene(false); pump(0.03)
            try verify(GLCursorBridge.cursorVisibility() != 0, "调度中心退出后丢失光标")
            engine.testScene(nil)
            engine.testRecognitionSuspended = false; engine.testIdentify([link]); pump(0.3)
            try verify(engine.testRole.map(CursorCatalog.family) == CursorCatalog.family(link), "自帧/外部切换后角色：\(engine.testRole ?? "nil")；\(engine.status)")
            try verify(GLCursorBridge.cursorVisibility() != 0, "运行层隐藏了系统光标")
            for resize in [horizontal, vertical, "com.apple.cursor.35"] {
                engine.testIdentify([resize]); pump(0.06)
                _ = GLCursorBridge.present(originalArrow)
                engine.injectObserved(.mouseMoved)
                pump(0.18)
                if engine.testRole.map(CursorCatalog.family) != CursorCatalog.family(arrow) {
                    try JSONSerialization.data(withJSONObject: engine.testStats, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("resize-failure.json"))
                    if let snapshot = GLCursorBridge.currentSnapshot() { try CursorImages.png(snapshot.image).write(to: root.appendingPathComponent("resize-failure.png")) }
                }
                try verify(engine.testRole.map(CursorCatalog.family) == CursorCatalog.family(arrow), "离开调整角色后仍残留：\(engine.testRole ?? "nil")")
            }
            print("PASS resize-to-native-arrow restoration")
            try verify(engine.stop() && !engine.hasRecovery, "停用未恢复备份")
            print("PASS runtime role isolation, click interruption, self-seed filtering, static wakeups and restore")
        } catch {
            if let runtime, let details = try? JSONSerialization.data(withJSONObject: runtime.testStats, options: [.prettyPrinted, .sortedKeys]) {
                try? details.write(to: root.appendingPathComponent("failure.json"))
            }
            _ = runtime?.stop(); renderer.stop(restoring: initial); print("FAIL", error.localizedDescription); exit(1)
        }
    }
}
