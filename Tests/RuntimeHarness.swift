import AppKit
import Darwin
import GalleryCore
import GalleryNative

/// Own-process checks: no mouse warps, OS input injection or app switching.
@main @MainActor
struct RuntimeHarness {
    static func verify(_ value: Bool, _ reason: String) throws { if !value { throw ThemeError.invalid(reason) } }
    static func matches(_ snapshot: GLCursorSnapshot, registered: [String: Any], source: Data? = nil) -> Bool {
        guard let actual = CursorFingerprint(image: snapshot.image, width: snapshot.size.width, height: snapshot.size.height,
            hotX: snapshot.hotSpot.x, hotY: snapshot.hotSpot.y), let data = registered["Representations"] as? [Data],
            let clip = try? CursorImages.fromCape(registered) else { return false }
        return (data + (source.map { [$0] } ?? [])).contains { image in
            guard let expected = CursorFingerprint(data: image, width: clip.width, height: clip.height, hotX: clip.hotX, hotY: clip.hotY) else { return false }
            return actual.distance(to: expected) <= 0.012
        }
    }
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
            var colorSeeds: [Int32] = []
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
                let seed = GLCursorBridge.cursorSeed(); colorSeeds.append(seed)
                try verify(renderer.confirmDisplayed(seed: seed, revision: renderer.imageRevision), "无法确认三色检查的当前图像")
                try verify(GLCursorBridge.cursorVisibility() != 0, "更新图像隐藏了系统光标")
            }
            try verify(!renderer.owns(seed: colorSeeds[0]) && !renderer.owns(seed: colorSeeds[1]) && renderer.owns(seed: colorSeeds[2]),
                       "同角色的旧动画帧仍被误当成当前画面")
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
            let denseClip = CursorClip(frames: [data[0], data[1], data[2], data[0], data[1], data[2], data[0], data[1], data[2]], frameDuration: 0.005)
            let dense = try PreparedCursors(roles: [CursorRole(id: "dense", name: "Dense", clips: ["normal": denseClip])]).clip(role: "dense", motion: .normal)!
            renderer.present(dense, role: "dense", motion: .normal, scale: 1, started: start, now: start + 0.034)
            try verify(abs((renderer.nextFrameDeadline ?? 0) - (start + 0.05)) < 0.00001,
                       "迟到帧使 60Hz 调度漂移")
            renderer.stop(restoring: initial)
            let releaseStart = ProcessInfo.processInfo.systemUptime
            renderer.present(prepared, role: "test", motion: .release, scale: 1, started: releaseStart, now: releaseStart)
            renderer.adoptReleaseFrame(1, role: "test", started: releaseStart, now: releaseStart + 0.006, clip: clip)
            renderer.present(prepared, role: "test", motion: .release, scale: 1, started: releaseStart, now: releaseStart + 0.007)
            try verify(renderer.displayedFrame == data[1], "已出现的后续松手帧又退回首帧")
            try verify(abs((renderer.nextFrameDeadline ?? 0) - (releaseStart + 0.106)) < 0.00001,
                       "接续已有帧改变了后续帧停留时长")
            renderer.present(prepared, role: "test", motion: .release, scale: 1, started: releaseStart, now: releaseStart + 0.12)
            try verify(renderer.displayedFrame == data[2], "接续已有帧后松手动画不再向前推进")
            renderer.stop(restoring: initial)
            print("PASS native frames, 300 switches, phase-aligned cadence, visibility and independent geometry")
            print("PASS visible release progress never rewinds; remaining frame duration preserved")
            let foreground = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(data[2]), size: NSSize(width: 32, height: 32)), hotSpot: .zero)
            try verify(GLCursorBridge.setBackgroundCursorUpdates(true) == 0, "无法启用诊断前台图像提交")
            _ = GLCursorBridge.present(foreground); pump(0.01)
            let foregroundSeed = GLCursorBridge.cursorSeed()
            renderer.testDelayedSeed = true
            renderer.present(prepared, role: "test", motion: .normal, scale: 1, started: start, now: start)
            try verify(!renderer.owns(seed: foregroundSeed), "延迟返回的旧前台编号被误记成 Gallery 所有")
            guard let pending = renderer.pendingImage else { throw ThemeError.invalid("延迟提交没有等待图像确认") }
            pump(0.01)
            var confirmed = false
            let acknowledgment = CursorRecognition(matcher: CursorMatcher())
            acknowledgment.probe(pendingImage: pending.fingerprint) { seed, _, ownImage, _ in
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
            pump(0.25)
            let copyNormal = GLCursorBridge.readCursor("com.apple.cursor.5")!
            let linkNormal = GLCursorBridge.readCursor(link)!
            engine.testPhysicalDown = true; engine.testIdentify([arrow]); pump(0.003)
            engine.injectObserved(.leftMouseDown); pump(0.12)
            try verify(engine.testMotion == .hold, "拖放交接检查尚未进入按住")
            try verify(GLCursorBridge.selectCursorIdentifier("com.apple.cursor.5") == 0, "无法在松手回调前重选拖放入口")
            pump(0.004)
            guard let preUp = GLCursorBridge.currentSnapshot() else { throw ThemeError.invalid("无法读取松手回调前的拖放图像") }
            let expectedHold = try CursorImages.capeDictionary(theme.roles.first(where: { $0.id == arrow })!.clip(.hold)!)
            try verify(matches(preUp, registered: expectedHold, source: theme.roles.first(where: { $0.id == arrow })!.clip(.hold)!.frames[0]),
                "Finder 在松手回调前重选拖放入口时会先闪回常态")
            let heldSubmissions = engine.testSubmissions
            pump(0.22)
            try verify(engine.testSubmissions == heldSubmissions, "静态按住仍持续重交注册资源")
            engine.testPhysicalDown = false; engine.injectObserved(.leftMouseUp)
            guard let currentRelease = GLCursorBridge.readCursor(arrow), let copyEntry = GLCursorBridge.readCursor("com.apple.cursor.5") else {
                throw ThemeError.invalid("未能读取松手与拖放注册入口")
            }
            let releaseImage = try CursorImages.fromCape(currentRelease), copyImage = try CursorImages.fromCape(copyEntry)
            try verify(CursorImages.signature(releaseImage.frames[0], hotX: releaseImage.hotX, hotY: releaseImage.hotY, width: releaseImage.width, height: releaseImage.height)
                == CursorImages.signature(copyImage.frames[0], hotX: copyImage.hotX, hotY: copyImage.hotY, width: copyImage.width, height: copyImage.height),
                "Finder 复制拖放入口仍指向常态图像，可在松手中途插回常态")
            try verify((currentRelease["FrameCount"] as? NSNumber)?.intValue == 1 && (copyEntry["FrameCount"] as? NSNumber)?.intValue == 1,
                       "松手入口意外使用可重启的原生动画")
            try verify(GLCursorBridge.selectCursorIdentifier("com.apple.cursor.5") == 0, "无法重选拖放入口")
            pump(0.004)
            guard let reselected = GLCursorBridge.currentSnapshot(), let dragFrame = GLCursorBridge.readCursor("com.apple.cursor.5") else {
                throw ThemeError.invalid("无法读取重选拖放入口后的实际图像")
            }
            try verify(matches(reselected, registered: dragFrame, source: engine.renderedFrame),
                "重选拖放入口后实际图像偏离当前松手帧")
            let cachedNormal = try CursorImages.fromCape(copyNormal)
            let cachedCursor = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(cachedNormal.frames[0]),
                size: NSSize(width: cachedNormal.width, height: cachedNormal.height)),
                hotSpot: NSPoint(x: cachedNormal.hotX, y: cachedNormal.hotY))
            _ = GLCursorBridge.present(cachedCursor)
            engine.testIdentify([arrow], applied: [arrow]); pump(0.005)
            guard let cachedRecovery = GLCursorBridge.currentSnapshot(), let expectedRecovery = GLCursorBridge.readCursor(arrow) else {
                throw ThemeError.invalid("无法读取缓存常态覆盖后的松手帧")
            }
            try verify(matches(cachedRecovery, registered: expectedRecovery, source: engine.renderedFrame),
                "前台选择缓存常态后，更新注册入口没有恢复当前松手帧")
            func imageKey(_ dictionary: [String: Any]) throws -> String {
                let clip = try CursorImages.fromCape(dictionary)
                guard let key = CursorImages.signature(clip.frames[0], hotX: clip.hotX, hotY: clip.hotY, width: clip.width, height: clip.height) else {
                    throw ThemeError.invalid("注册光标没有有效图像指纹")
                }
                return key
            }
            try verify(try imageKey(GLCursorBridge.readCursor(link)!) == imageKey(linkNormal), "箭头松手覆盖了不同的链接常态")
            let uninterruptedRelease = engine.testMotionStartedAt
            pump(0.04)
            let oldRelease = NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(copyImage.frames[0]),
                size: NSSize(width: copyImage.width, height: copyImage.height)),
                hotSpot: NSPoint(x: copyImage.hotX, y: copyImage.hotY))
            engine.testRecognitionSuspended = false
            _ = GLCursorBridge.present(oldRelease); pump(0.04)
            engine.testRecognitionSuspended = true
            try verify(engine.testMotion == .release && engine.testMotionStartedAt == uninterruptedRelease,
                       "旧帧重选改变了当前松手阶段或起点")
            guard let afterOldFrame = GLCursorBridge.currentSnapshot(), let expectedCurrentFrame = GLCursorBridge.readCursor(arrow) else {
                throw ThemeError.invalid("无法读取旧帧重选后的画面")
            }
            try verify(matches(afterOldFrame, registered: expectedCurrentFrame, source: engine.renderedFrame), "旧松手首帧重选后没有继续当前帧")
            pump(0.25)
            try verify(try imageKey(GLCursorBridge.readCursor("com.apple.cursor.5")!) == imageKey(copyNormal), "拖放入口未还原其独立常态")
            print("PASS equivalent drag entry mirrors static release frame; other roles isolated; normals restored")
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
            let textEpoch = engine.testMotionStartedAt
            for _ in 0..<20 {
                guard let textFrame = GLCursorBridge.readCursor("com.apple.coregraphics.IBeam") else { throw ThemeError.invalid("无法读取文字当前帧") }
                let sourceFrame = engine.renderedFrame
                _ = GLCursorBridge.selectCursorIdentifier("com.apple.coregraphics.IBeam")
                let until = ProcessInfo.processInfo.systemUptime + 0.04
                var sameImage = false
                repeat {
                    if let snapshot = GLCursorBridge.currentSnapshot(), matches(snapshot, registered: textFrame, source: sourceFrame) { sameImage = true; break }
                } while ProcessInfo.processInfo.systemUptime < until
                try verify(sameImage, "文字角色重选后图像与当前动画帧不一致")
                engine.injectObserved(.mouseMoved); pump(0.012)
            }
            try verify(engine.testMotionStartedAt == textEpoch, "在文字中移动重置了常态动画起点")
            try verify((GLCursorBridge.readCursor("com.apple.coregraphics.IBeam")?["FrameCount"] as? NSNumber)?.intValue == 1,
                       "文字常态仍登记为可在移动时从头播放的原生循环")
            print("PASS repeated text cursor selection preserves animation epoch and registered current frame")
            let animationCPU = cpu(), animationTime = ProcessInfo.processInfo.systemUptime
            let animationSubmissions = engine.testSubmissions
            for _ in 0..<180 {
                // Keep this own-process benchmark's role controlled even if
                // the user's foreground app rebuilds its cursor regions.
                engine.testIdentify(["com.apple.coregraphics.IBeam"]); pump(1.0 / 60)
            }
            print("PERF animatedCPU=\((cpu() - animationCPU) / (ProcessInfo.processInfo.systemUptime - animationTime) * 100) submissions=\(engine.testSubmissions - animationSubmissions)")
            try verify(engine.testSubmissions - animationSubmissions > 30, "文字动画性能采样没有实际持续播放")
            engine.testScene(true); pump(0.03)
            try verify(GLCursorBridge.cursorVisibility() != 0 && engine.testMissionControl, "调度中心路径丢失光标")
            engine.testPhysicalDown = true; engine.injectObserved(.leftMouseDown); pump(0.03)
            try verify(engine.testMotion == .press && engine.testFrameDeadline != nil, "调度中心点击仍被强制为静态常态")
            pump(0.3); try verify(engine.testMotion == .hold, "调度中心未保持按住阶段")
            engine.testPhysicalDown = false; engine.injectObserved(.leftMouseUp); pump(0.02)
            try verify(engine.testMotion == .release && engine.testFrameDeadline != nil, "调度中心松手动画没有推进")
            engine.testScene(false); pump(0.03)
            try verify(GLCursorBridge.cursorVisibility() != 0, "调度中心退出后丢失光标")
            engine.testScene(nil)
            engine.testPhysicalDown = nil
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
            var separateTheme = theme
            for index in separateTheme.roles.indices where separateTheme.roles[index].id == "com.apple.cursor.5" {
                separateTheme.roles[index].scale = 1.4
            }
            engine.start(separateTheme); engine.testRecognitionSuspended = true
            try verify(engine.enabled, engine.error ?? "独立拖放大小启用失败")
            let separateCopy = GLCursorBridge.readCursor("com.apple.cursor.5")!
            engine.testIdentify([arrow]); engine.testPhysicalDown = true; engine.injectObserved(.leftMouseDown)
            engine.testPhysicalDown = false; engine.injectObserved(.leftMouseUp)
            try verify(try imageKey(GLCursorBridge.readCursor("com.apple.cursor.5")!) == imageKey(separateCopy),
                       "相同素材但不同尺寸的拖放角色被错误合并")
            try verify(engine.stop() && !engine.hasRecovery, "独立拖放检查未恢复备份")
            print("PASS different-size drag role stays independent during arrow release")
            print("PASS runtime role isolation, click interruption, self-seed filtering, static wakeups and restore")
        } catch {
            if let snapshot = GLCursorBridge.currentSnapshot(), let data = try? CursorImages.png(snapshot.image) {
                try? data.write(to: root.appendingPathComponent("failure-cursor.png"))
                let info: [String: Any] = ["width": snapshot.size.width, "height": snapshot.size.height,
                    "hotX": snapshot.hotSpot.x, "hotY": snapshot.hotSpot.y, "seed": snapshot.seed]
                try? JSONSerialization.data(withJSONObject: info).write(to: root.appendingPathComponent("failure-cursor.json"))
            }
            if let runtime, let details = try? JSONSerialization.data(withJSONObject: runtime.testStats, options: [.prettyPrinted, .sortedKeys]) {
                try? details.write(to: root.appendingPathComponent("failure.json"))
            }
            _ = runtime?.stop(); renderer.stop(restoring: initial); print("FAIL", error.localizedDescription); exit(1)
        }
    }
}
