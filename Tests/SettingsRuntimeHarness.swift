import AppKit
import Combine
import GalleryCore
import GalleryNative

/// Uses an isolated library and recovery journal. No OS input injection, mouse
/// movement, user preference changes or production-library writes.
@main @MainActor
struct SettingsRuntimeHarness {
    static func verify(_ value: Bool, _ reason: String) throws { if !value { throw ThemeError.invalid(reason) } }
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func waitFor(_ store: GalleryStore) throws {
        let end = Date().addingTimeInterval(10)
        while store.importing && Date() < end { pump(0.01) }
        try verify(!store.importing, "目录操作超时")
    }
    static func imageMatches(_ runtime: CursorRuntime, role: String) -> Bool {
        guard let current = GLCursorBridge.currentSnapshot(), let dictionary = GLCursorBridge.readCursor(role) else { return false }
        var matcher = CursorMatcher()
        matcher.addRepresentations(dictionary, role: role, applied: true)
        return matcher.identify(image: current.image, width: current.size.width, height: current.size.height,
            hotX: current.hotSpot.x, hotY: current.hotSpot.y).appliedRoles.contains(role)
    }
    static func visiblePlayback(_ runtime: CursorRuntime, role: String) -> Bool {
        // A WindowServer image update is asynchronous to registration. Sample
        // across several refreshes instead of requiring the newest resource
        // to have reached the screen in the same instant it was registered.
        var hits = 0
        for _ in 0..<10 {
            runtime.testIdentify([role]); pump(0.023)
            if imageMatches(runtime, role: role) { hits += 1 }
        }
        return hits >= 2
    }
    static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = CursorRuntime(recoveryURL: root.appendingPathComponent("recovery.plist"))
        defer { _ = engine.stop() }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Themes"), withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            var theme = try source.pathExtension == "gallery" ? ThemeFiles.load(source) : WindowsThemeImport.load(source)
            theme.pointerScale = 1.9; theme.idleEnabled = false
            for index in theme.roles.indices where CursorCatalog.isText(theme.roles[index].id) { theme.roles[index].scale = 0.75 }
            engine.start(theme); try verify(engine.enabled, engine.error ?? "启动失败")
            engine.testRecognitionSuspended = true; engine.testPhysicalDown = false
            let registered = engine.testStats["registeredRoles"] as! [String]
            var checked = Set<String>()
            for role in theme.roles where registered.contains(role.id) && !CursorCatalog.isResize(role.id) {
                guard checked.insert(CursorCatalog.family(role.id)).inserted else { continue }
                if CursorCatalog.isText(role.id) {
                    let cached = role.clip(.normal)!.scaled(by: theme.pointerScale * role.scale)
                    let image = NSImage(cgImage: try CursorImages.bitmap(cached.frames[0]), size: NSSize(width: cached.width, height: cached.height))
                    _ = GLCursorBridge.present(NSCursor(image: image, hotSpot: NSPoint(x: cached.hotX, y: cached.hotY)))
                } else { _ = GLCursorBridge.selectCursorIdentifier(role.id) }
                engine.testIdentify([role.id]); pump(0.01)
                if role.clip(.normal)!.frames.count > 1 {
                    var frames = Set<Data>(), actualMatches = 0
                    for _ in 0..<12 {
                        engine.testIdentify([role.id]); pump(0.025)
                        if let frame = engine.renderedFrame { frames.insert(frame) }
                        if imageMatches(engine, role: role.id) { actualMatches += 1 }
                    }
                    try verify(frames.count > 1, "常态动画未推进：\(role.id)")
                    if CursorCatalog.isText(role.id) { try verify(actualMatches > 2, "文字常态图像未显示：\(role.id)") }
                }
                if role.clip(.press) != nil {
                    engine.testPhysicalDown = true; engine.injectObserved(.leftMouseDown)
                    let epoch = engine.testMotionStartedAt, first = engine.renderedFrame
                    pump(0.045); engine.testIdentify([role.id])
                    try verify(engine.testMotion == .press || engine.testMotion == .hold, "按下阶段丢失：\(role.id)")
                    try verify(engine.renderedFrame != first, "按下动画未推进：\(role.id)")
                    try verify(engine.testMotionStartedAt == epoch, "按下起点被角色重选重置：\(role.id)")
                    if CursorCatalog.isText(role.id) { try verify(imageMatches(engine, role: role.id), "文字按下图像未显示：\(role.id)") }
                    engine.testPhysicalDown = false; engine.injectObserved(.leftMouseUp)
                    pump(max(role.clip(.press)?.duration ?? 0, role.clip(.release)?.duration ?? 0) + 0.05)
                }
                print("PASS role normal/press playback \(role.id)")
            }
            let text = "com.apple.coregraphics.IBeam"
            _ = GLCursorBridge.selectCursorIdentifier(text); engine.testIdentify([text])
            // Registration changes the visible seed. Exercise the production
            // recognizer here; suspending it would intentionally block drawing
            // until another synthetic testIdentify call supplies that seed.
            engine.testRecognitionSuspended = false
            engine.setRoleScale(1.1, for: text); pump(0.3)
            let resized = GLCursorBridge.readCursor(text)!
            let expected = theme.roles.first { $0.id == text }!.clip(.normal)!.scaled(by: 1.9 * 1.1)
            try verify((resized["PointsWide"] as! NSNumber).doubleValue == expected.width.rounded(), "独立大小未更新对齐后的注册资源")
            engine.testPhysicalDown = true; engine.injectObserved(.leftMouseDown); pump(0.04)
            try verify(imageMatches(engine, role: text), "改变大小后文字按下图像未显示")
            engine.testPhysicalDown = false; engine.injectObserved(.leftMouseUp); pump(1.5)
            engine.setScale(1.3); engine.setRoleScale(0.8, for: "com.apple.cursor.19"); engine.setRoleScale(0.9, for: text)
            let until = Date().addingTimeInterval(3)
            while ((GLCursorBridge.readCursor(text)?["PointsWide"] as? NSNumber)?.doubleValue ?? 0) != (32 * 1.3 * 0.9).rounded() && Date() < until { pump(0.02) }
            engine.testIdentify([text]); pump(0.04)
            try verify((GLCursorBridge.readCursor(text)!["PointsWide"] as! NSNumber).doubleValue == (32 * 1.3 * 0.9).rounded(),
                       "连续全局/独立大小更新丢失待注册角色")
            try verify(visiblePlayback(engine, role: text), "连续更改大小后文字常态不可见")
            _ = engine.stop(); try verify(!engine.hasRecovery, "恢复记录未清理")
            engine.start(theme); try verify(engine.enabled, engine.error ?? "小尺寸主题启动失败")
            engine.setScale(0.25); engine.setRoleScale(0.25, for: text)
            let smallDeadline = Date().addingTimeInterval(3)
            while ((GLCursorBridge.readCursor(text)?["PointsWide"] as? NSNumber)?.doubleValue ?? 0) != 2 && Date() < smallDeadline { pump(0.02) }
            try verify((GLCursorBridge.readCursor(text)?["PointsWide"] as? NSNumber)?.doubleValue == 2, "25% 整体与角色组合大小未生效")
            _ = engine.stop(); try verify(!engine.hasRecovery, "小尺寸检查未恢复")
            print("PASS live role resize and 25% bounds retain native text animation path")

            var other = theme; other.name = "Editable theme B"
            let rows = [LibraryTheme(theme: theme), LibraryTheme(theme: other)]
            for (value, row) in zip([theme, other], rows) { try ThemeFiles.save(value, to: root.appendingPathComponent("Themes/" + row.id + ".gallery")) }
            try ThemeLibrary.saveIndex(rows, at: root.appendingPathComponent("themes.json"))
            let store = GalleryStore(rootURL: root, runtime: engine); store.saveNow(wait: true); store.applyCurrentTheme()
            try verify(engine.enabled && store.editingActiveTheme, "启用主题未被锁定")
            let active = store.theme; store.selectedMotion = .normal
            store.edit { $0.hotX = 1 }; store.setDefaultIdleDelay(29); store.setUsesNative(true)
            try verify(store.theme == active, "正在使用的主题仍可修改动画")
            store.selectTheme(rows[1].id); try waitFor(store)
            try verify(engine.enabled && !store.editingActiveTheme, "未使用的主题被锁定")
            store.selectedMotion = .normal; store.edit { $0.hotX = 1 }
            try verify(store.clip?.hotX == 1, "未使用主题的编辑被拒绝")
            try verify(store.duplicateFrame(at: 0) != nil, "未使用主题无法复制帧")
            var libraryUpdates = 0
            let observation = store.$library.dropFirst().sink { _ in libraryUpdates += 1 }
            let began = Date()
            for number in 1...60 {
                store.setDefaultIdleDelay(Double(number)); store.setRoleScale(0.5 + Double(number) / 100)
            }
            observation.cancel()
            try verify(libraryUpdates == 0, "连续滑块变更仍反复发布不变的目录缩略图")
            print("PASS 120 size/wait model changes without gallery refresh (\(Int(Date().timeIntervalSince(began) * 1000)) ms)")
            store.setDefaultIdleDelay(29); store.setRoleScale(1.3); store.setAppearance(CursorAppearance(smoothEdges: false, shadow: true))
            store.saveNow(wait: true)
            let saved = try ThemeFiles.load(root.appendingPathComponent("Themes/" + rows[1].id + ".gallery"))
            try verify(saved.idleDelay == 29 && saved.roles[0].scale == 1.3 && saved.appearance.shadow, "滑块或外观未保存")
            try verify(try ThemeFiles.load(root.appendingPathComponent("Themes/" + rows[0].id + ".gallery")) == active, "编辑其他主题修改了启用主题")
            try verify(engine.testRoleScale(active.roles[0].id) == active.roles[0].scale, "编辑其他主题改变了运行时大小")
            _ = engine.stop(); try verify(!engine.hasRecovery, "最后恢复失败")
            print("PASS active theme locked; other theme editable; size, wait and appearance saved independently")
            var staticText = theme
            for index in staticText.roles.indices where CursorCatalog.family(staticText.roles[index].id) == text {
                if let variant = staticText.roles[index].variants[Motion.normal.rawValue]?.first(where: { $0.clip.frames.count == 1 }) {
                    staticText.roles[index].selectVariant(variant.id, for: .normal)
                }
            }
            try verify(staticText.roles.first { $0.id == text }!.clip(.normal)!.frames.count == 1, "缺少静态文字测试素材")
            engine.start(staticText); try verify(engine.enabled, engine.error ?? "静态文字主题启动失败")
            engine.testRecognitionSuspended = true; engine.testPhysicalDown = false
            let still = staticText.roles.first { $0.id == text }!.clip(.normal)!.scaled(by: 1.9 * 0.75)
            _ = GLCursorBridge.present(NSCursor(image: NSImage(cgImage: try CursorImages.bitmap(still.frames[0]), size: NSSize(width: still.width, height: still.height)),
                                               hotSpot: NSPoint(x: still.hotX, y: still.hotY)))
            engine.testIdentify([text]); pump(0.04)
            engine.testPhysicalDown = true; engine.injectObserved(.leftMouseDown)
            try verify(visiblePlayback(engine, role: text), "静态文字版本的点按动画不可见")
            _ = engine.stop(); try verify(!engine.hasRecovery, "静态文字检查未恢复")
            print("PASS static text variant with cached app cursor still plays animated press")
            var styled = theme; styled.appearance = CursorAppearance(smoothEdges: false, shadow: true)
            engine.start(styled); try verify(engine.enabled, engine.error ?? "外观主题启动失败")
            engine.testRecognitionSuspended = true; engine.testPhysicalDown = false
            _ = GLCursorBridge.selectCursorIdentifier(text); engine.testIdentify([text]); pump(0.04)
            try verify(visiblePlayback(engine, role: text), "阴影文字常态未显示")
            engine.testPhysicalDown = true; engine.injectObserved(.leftMouseDown); pump(0.04)
            try verify(visiblePlayback(engine, role: text), "阴影文字按下未显示")
            _ = engine.stop(); try verify(!engine.hasRecovery, "外观检查未恢复")
            print("PASS cached shadow and sharp sampling retain native text normal/press images and restore")
            if CommandLine.arguments.count > 3 {
                var looping = try ThemeFiles.load(URL(fileURLWithPath: CommandLine.arguments[3]))
                looping.idleEnabled = false
                engine.start(looping); engine.testRecognitionSuspended = true; engine.testPhysicalDown = false
                for role in ["com.apple.coregraphics.Arrow", text] {
                    let source = looping.roles.first { $0.id == role }!.clip(.normal)!
                    try verify((2...24).contains(source.frames.count), "缺少短常态动画")
                    _ = GLCursorBridge.selectCursorIdentifier(role); engine.testIdentify([role])
                    try verify(visiblePlayback(engine, role: role), "整段原生常态未显示")
                    let registered = GLCursorBridge.readCursor(role)!
                    let reference = CursorAnimationImages(dictionary: registered)
                    let snapshot = GLCursorBridge.currentSnapshot()!
                    try verify((registered["FrameCount"] as! NSNumber).intValue == source.frames.count, "整段动画帧数被改变")
                    try verify(reference?.matches(image: snapshot.image, size: snapshot.size, hotSpot: snapshot.hotSpot) == true, "整段动画身份未确认")
                    try verify(engine.testFrameDeadline == nil, "整段原生常态仍逐帧唤醒")
                    var wrong = registered; wrong["HotSpotX"] = NSNumber(value: 0)
                    if role == text {
                        try verify(CursorAnimationImages(dictionary: wrong)?.matches(image: snapshot.image, size: snapshot.size, hotSpot: snapshot.hotSpot) == false,
                                   "不同热点被错误确认为当前动画")
                    }
                    engine.setRoleScale(0.9, for: role); pump(0.25)
                    try verify(visiblePlayback(engine, role: role), "整段动画调整大小后未显示")
                    try verify(engine.testFrameDeadline == nil, "调整大小后退回逐帧播放")
                    print("PASS full native loop, exact identity and role resize \(role)")
                }
                _ = engine.stop(); try verify(!engine.hasRecovery, "整段原生动画检查未恢复")
            }
        } catch {
            print("FAIL \(error.localizedDescription)")
            if let data = try? JSONSerialization.data(withJSONObject: engine.testStats, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("failure-state.json"))
            }
            if let current = GLCursorBridge.currentSnapshot() {
                try? CursorImages.png(current.image).write(to: root.appendingPathComponent("failure-visible.png"))
                print("Visible size \(current.size); hotspot \(current.hotSpot)")
            }
            if let registered = GLCursorBridge.readCursor("com.apple.coregraphics.IBeam"), let data = (registered["Representations"] as? [Data])?.first {
                try? data.write(to: root.appendingPathComponent("failure-registered.png"))
                print("Registered size \(registered["PointsWide"] ?? "nil"); hotspot \(registered["HotSpotX"] ?? "nil")")
            }
            _ = engine.stop(); exit(1)
        }
    }
}
