import AppKit
import Combine
import GalleryCore
import GalleryNative

/// Only unselected, connection-local frame slots are allocated. No cursor is
/// selected, registered globally, hidden, moved, or restored by this harness.
@main @MainActor struct EnergyHarness {
    static func check(_ value: Bool, _ reason: String) throws {
        if !value { throw ThemeError.invalid(reason) }
    }
    static func clip(_ frames: [Data], duration: Double = 0.05) -> CursorClip {
        CursorClip(frames: frames, frameDuration: duration, hotX: 3, hotY: 7)
    }
    static func main() {
        do { try run() } catch { print("FAIL", error.localizedDescription); exit(1) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let deadlineTimer = CursorDeadlineTimer()
        var deliveries: [String] = []
        let due = ProcessInfo.processInfo.systemUptime + 0.02
        try check(deadlineTimer.arm(at: due, precise: false) { _ in deliveries.append("watchdog") }, "Initial watchdog was not armed")
        try check(!deadlineTimer.arm(at: due + 0.2, precise: false) { _ in deliveries.append("late") }, "A later request postponed existing work")
        try check(deadlineTimer.arm(at: due + 0.1, precise: true) { _ in deliveries.append("promoted") }, "Animation did not promote the relaxed source")
        try check(deadlineTimer.precise && deadlineTimer.deadline! <= due, "Promoting precision lost the earlier deadline")
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        try check(deliveries == ["promoted"] && deadlineTimer.deadline == nil, "A cancelled source fired, or a one-shot source repeated")
        deadlineTimer.arm(at: ProcessInfo.processInfo.systemUptime + 0.01, precise: true) { _ in deliveries.append("cancelled") }
        deadlineTimer.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        try check(deliveries == ["promoted"], "Cancellation allowed a stale callback")
        deadlineTimer.arm(at: ProcessInfo.processInfo.systemUptime + 0.001, precise: true) { _ in deliveries.append("already-queued") }
        Thread.sleep(forTimeInterval: 0.008)
        deadlineTimer.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        try check(deliveries == ["promoted"], "A callback already queued to the main run loop survived cancellation")
        deadlineTimer.arm(at: ProcessInfo.processInfo.systemUptime + 0.001, precise: true) { _ in
            deliveries.append("first")
            deadlineTimer.arm(at: ProcessInfo.processInfo.systemUptime + 0.001, precise: true) { _ in deliveries.append("second") }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try check(deliveries == ["promoted", "first", "second"] && deadlineTimer.deadline == nil, "Callback rearming lost a deadline or kept polling")
        var deliveredInModalMode = false, nestedFinished = false
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                deadlineTimer.arm(at: ProcessInfo.processInfo.systemUptime + 0.002, precise: true) { _ in deliveredInModalMode = true }
                let end = Date().addingTimeInterval(0.08)
                while !deliveredInModalMode && Date() < end { RunLoop.main.run(mode: .modalPanel, before: end) }
                nestedFinished = deliveredInModalMode
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try check(nestedFinished, "Opening a native modal panel blocked frame timing")
        print("PASS deadline timer keeps earlier work, promotes relaxed timers, cancels stale callbacks and fires only once including callback rearming")
        let pictures = try (0..<240).map { n -> Data in
            let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for pixel in 0..<(32 * 32) {
                bytes[pixel * 4] = UInt8(n); bytes[pixel * 4 + 1] = UInt8((n * 37) % 256)
                bytes[pixel * 4 + 2] = UInt8((n * 101) % 256); bytes[pixel * 4 + 3] = 255
            }
            return try CursorImages.png(context.makeImage()!)
        }
        try check(Set(pictures).count == 240, "Synthetic frames are not distinct")
        let roles = [
            CursorRole(id: "a", name: "A", clips: ["idle": clip(pictures), "release": clip([pictures[4], pictures[5], pictures[6], pictures[0]])]),
            CursorRole(id: "b", name: "B", clips: ["release": clip(Array(repeating: pictures[0], count: 8))]),
            CursorRole(id: "c", name: "C", clips: ["press": clip([pictures[1], pictures[2], pictures[0]])]),
            CursorRole(id: "spare", name: "Spare", clips: ["press": clip(Array(pictures.prefix(64)), duration: 0.02)])
        ]
        let prepared = try PreparedCursors(roles: roles)
        let long = prepared.clip(role: "a", motion: .idle)!, aRelease = prepared.clip(role: "a", motion: .release)!
        let b = prepared.clip(role: "b", motion: .release)!, c = prepared.clip(role: "c", motion: .press)!
        let renderer = SystemCursorRenderer(); renderer.testRasterScale = 2
        defer { renderer.stop(restoring: nil) }
        var coldMisses = 0, warmMisses = 0
        let coldStart = ProcessInfo.processInfo.systemUptime
        for index in long.frames.indices {
            if try !renderer.testPrepareFrame(long, index: index, role: "a", motion: .idle, scale: 1.9) { coldMisses += 1 }
        }
        let coldTime = ProcessInfo.processInfo.systemUptime - coldStart
        let warmStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2 {
            for index in long.frames.indices {
                if try !renderer.testPrepareFrame(long, index: index, role: "a", motion: .idle, scale: 1.9) { warmMisses += 1 }
            }
        }
        let warmTime = ProcessInfo.processInfo.systemUptime - warmStart
        print("CACHE coldMisses=\(coldMisses), warmMisses=\(warmMisses), count=\(renderer.testNativeFrameCount), bytes=\(renderer.testNativeFrameBytes), budget=\(renderer.testNativeFrameBudget)")
        try check(coldMisses == 240 && warmMisses == 0, "Long loop regenerated cached frames")
        try check(renderer.testNativeFrameBytes <= CursorFrameCacheBudget.maximumBytes, "Frame cache exceeded its hard byte limit")
        print("PASS 240-frame loop: coldMisses=\(coldMisses), warmMisses=\(warmMisses), bytes=\(renderer.testNativeFrameBytes), coldMs=\(coldTime * 1000), twoWarmLoopsMs=\(warmTime * 1000)")

        renderer.warmInteraction(prepared.clip(role: "spare", motion: .press)!, role: "spare", motion: .press, scale: 1.9, limit: 64)
        for index in long.frames.indices {
            try check(try renderer.testPrepareFrame(long, index: index, role: "a", motion: .idle, scale: 1.9), "Inactive warm-up evicted the active loop")
        }
        try check(renderer.testNativeFrameBytes <= renderer.testNativeFrameBudget, "Inactive warm-up exceeded the active budget")
        print("PASS active animation survives unrelated prewarming within bounded memory")

        let beforeShared = renderer.testNativeFrameCount
        try check(try renderer.testPrepareFrame(b, index: 7, role: "b", motion: .release, scale: 1.9), "Identical role image was not shared")
        try check(try renderer.testPrepareFrame(c, index: 2, role: "c", motion: .press, scale: 1.9), "Identical press image was not shared")
        try check(try renderer.testPrepareFrame(aRelease, index: 3, role: "a", motion: .release, scale: 1.9), "Identical release image was not shared")
        try check(renderer.testNativeFrameCount == beforeShared, "Role aliases duplicated raster resources")
        try check(renderer.testRecoveryIndices(aRelease, role: "a", scale: 1.9).compactMap { $0 } == [3], "Role A adopted another role's release index")
        try check(renderer.testRecoveryIndices(b, role: "b", scale: 1.9).compactMap { $0 } == [7], "Role B adopted another role's release index")
        try check(renderer.testRecoveryIndices(c, role: "c", scale: 1.9).allSatisfy { $0 == nil }, "A press-only role inherited release recovery")
        try check(renderer.testRoleOwnershipIsIndependent(c, scale: 1.9), "Sharing an image merged role ownership")
        print("PASS shared raster resources keep role ownership and release indices independent")

        try check(try renderer.testPrepareFrame(c, index: 2, role: "c", motion: .press, scale: 1.9001), "Equivalent displayed geometry allocated another image")
        try check(try !renderer.testPrepareFrame(c, index: 2, role: "c", motion: .press, scale: 0.75), "Different role sizes reused the wrong raster")
        renderer.testRasterScale = 1
        try check(try !renderer.testPrepareFrame(c, index: 2, role: "c", motion: .press, scale: 1.9), "Backing resolution was omitted from the raster key")
        renderer.testRasterScale = 2
        renderer.configureNativeNormals([:], smoothEdges: false)
        try check(try !renderer.testPrepareFrame(c, index: 2, role: "c", motion: .press, scale: 1.9), "Smoothing was omitted from the raster key")
        try check(renderer.testNativeFrameBytes <= CursorFrameCacheBudget.maximumBytes, "Raster variants exceeded the hard byte limit")
        print("PASS equivalent scale reuse, independent sizes, screen resolution and smoothing")

        let warmer = SystemCursorRenderer(); warmer.testRasterScale = 2
        let press = prepared.clip(role: "spare", motion: .press)!
        let firstCold = ProcessInfo.processInfo.systemUptime
        _ = try warmer.testPrepareFrame(press, index: 0, role: "spare", motion: .press, scale: 1.9)
        let coldMs = (ProcessInfo.processInfo.systemUptime - firstCold) * 1000
        let mainBuilds = warmer.testMainFrameBuilds
        warmer.warmInteractions([(.press, press)], role: "spare", scale: 1.9)
        let warmDeadline = ProcessInfo.processInfo.systemUptime + 8
        while warmer.testBackgroundFrameBuilds < press.frames.count - 1 && ProcessInfo.processInfo.systemUptime < warmDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let warmProbe = ProcessInfo.processInfo.systemUptime
        for index in press.frames.indices {
            try check(try warmer.testPrepareFrame(press, index: index, role: "spare", motion: .press, scale: 1.9), "Warm interaction had a cold frame on input")
        }
        let warmMs = (ProcessInfo.processInfo.systemUptime - warmProbe) * 1000
        try check(warmer.testMainFrameBuilds == mainBuilds, "Background preparation still rasterized on input/main")
        try check(warmer.testNativeFrameBytes <= CursorFrameCacheBudget.maximumBytes, "Interaction warming exceeded memory budget")
        let beforeCancel = warmer.testNativeFrameCount
        warmer.warmInteractions([(.press, press)], role: "spare", scale: 0.7)
        warmer.cancelInteractionWarmup()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        try check(warmer.testNativeFrameCount == beforeCancel, "Cancelled role warm-up installed unused frames")
        warmer.warmInteractions([(.press, press)], role: "spare", scale: 0.8)
        warmer.stop(restoring: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        try check(warmer.testNativeFrameCount == 0, "Late background frame survived stop")
        print("PASS interaction worker prepares every frame; zero subsequent main raster builds; bounded memory/stop invalidation. coldFrameMs=\(coldMs), 64WarmLookupsMs=\(warmMs)")

        let streaming = SystemCursorRenderer(); streaming.testUnselectedLoops = true; streaming.testRasterScale = 2
        let arrowID = "com.apple.coregraphics.Arrow"
        let largeClip = CursorClip(frames: pictures, frameDuration: 0.095, width: 128, height: 128, hotX: 3, hotY: 7)
        let streamingRole = CursorRole(id: arrowID, name: "Large idle", clips: ["normal": clip([pictures[0]]), "idle": largeClip])
        let large = try PreparedCursors(roles: [streamingRole]).clip(role: arrowID, motion: .idle)!
        streaming.configureNativeNormals([arrowID: try CursorImages.capeDictionary(clip([pictures[0]]))])
        try check(!CursorFrameCacheBudget(uniqueFrames: 240, bytesPerFrame: CursorRasterGeometry(largeClip).rasterBytes(maximumScale: 2)).retainsActiveClip,
                  "Streaming fixture unexpectedly fits a whole cycle")
        for index in 0..<280 {
            streaming.present(large, role: arrowID, motion: .idle, scale: 1, started: 1000,
                              now: 1000 + Double(index) * largeClip.frameDuration + 0.000001, synchronizeRegistration: true)
            try check(streaming.displayedFrame == large.frames[index % 240].data, "Streaming changed idle frame order")
            try check(streaming.testPendingPlaybackBuilds <= 3, "Streaming queued more than three future changes")
            let due = Date().addingTimeInterval(3)
            while streaming.testPendingPlaybackBuilds > 0 && Date() < due {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            try check(streaming.testPendingPlaybackBuilds == 0, "Idle lookahead did not finish")
            try check(streaming.testNativeFrameBytes <= CursorFrameCacheBudget.maximumBytes, "Streaming exceeded 48 MiB")
        }
        try check(streaming.testMainFrameBuilds == 1, "Oversized idle still rasterizes on the main thread after its first frame")
        streaming.present(large, role: arrowID, motion: .idle, scale: 0.8, started: 2000, now: 2000, synchronizeRegistration: true)
        _ = try streaming.testPrepareFrame(c, index: 0, role: "new-focus", motion: .press, scale: 1)
        let changedFocusCount = streaming.testNativeFrameCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        try check(streaming.testPendingPlaybackBuilds == 0 && streaming.testNativeFrameCount == changedFocusCount,
                  "Old idle worker installed frames after a role/phase change")
        streaming.present(large, role: arrowID, motion: .idle, scale: 0.7, started: 3000, now: 3000, synchronizeRegistration: true)
        streaming.stop(restoring: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        try check(streaming.testNativeFrameCount == 0 && streaming.testPendingPlaybackBuilds == 0, "Idle worker installed a frame after stop")
        print("PASS oversized 240-frame idle streams through wrap: one cold main build, next three changes on worker, 48 MiB bound, stop invalidation")

        let nativeClip = clip([pictures[0]])
        let normal = try CursorImages.capeDictionary(nativeClip)
        let ids = ["com.apple.cursor.17", "com.apple.cursor.18", "com.apple.cursor.11", "com.apple.cursor.12", "com.apple.coregraphics.IBeam", "com.apple.cursor.1"]
        let dictionaries = Dictionary(uniqueKeysWithValues: ids.map { ($0, normal) })
        renderer.configureNativeNormals(dictionaries, independentRoles: true)
        for id in ids.prefix(4) {
            try check(renderer.testGuardedIdentifiers(for: id) == [id], "Identical artwork merged distinct native playback destinations")
        }
        try check(Set(renderer.testGuardedIdentifiers(for: "com.apple.coregraphics.IBeam")) == Set(ids.suffix(2)), "True native aliases stopped sharing their OS slot")
        renderer.configureNativeNormals([:])
        print("PASS identical artwork keeps detailed native playback groups independent")

        for count in [2, 48] {
            let arrow = "com.apple.coregraphics.Arrow", text = "com.apple.coregraphics.IBeam"
            let still = clip([pictures[0]])
            let animation = clip(Array(pictures.prefix(count)), duration: 0.03)
            let click = clip([pictures[2], pictures[3]], duration: 0.1)
            var sceneTheme = GalleryTheme(name: "Unselected system action", roles: [arrow, text].map {
                CursorRole(id: $0, name: $0, clips: ["normal": still, "idle": animation,
                    "press": click, "hold": still, "release": click])
            })
            sceneTheme.idleDelay = 0.07
            let sceneRuntime = CursorRuntime(); sceneRuntime.testBeginUnregistered(sceneTheme)
            do {
                defer { sceneRuntime.testEndUnregistered() }
                try sceneRuntime.testPrepareUnselectedPlayback()
                for _ in 0..<3 {
                    sceneRuntime.testIdentify([text]); sceneRuntime.testStartIdle()
                    let idleStarted = sceneRuntime.testMotionStartedAt
                    sceneRuntime.testSceneNotice(1400)
                    try check(sceneRuntime.testMotion == .idle && sceneRuntime.testMotionStartedAt == idleStarted,
                        "Unreliable Space start changed playback under completion-only policy")
                    // No touch/key input was delivered: system completion alone
                    // must work for gestures, hotkeys and third-party tools.
                    sceneRuntime.testSceneNotice(1401)
                    try check(sceneRuntime.testMotion == .normal && sceneRuntime.testRole == text
                        && sceneRuntime.renderedFrame == pictures[0],
                        "System Space completion did not replace idle with the normal role")
                    RunLoop.main.run(until: Date().addingTimeInterval(0.035)); sceneRuntime.testSceneTick()
                    try check(sceneRuntime.testMotion == .normal, "Space completion reused the elapsed idle delay")
                    // Native and Workspace can both report the same completion;
                    // the later report must leave a fresh delay, never old idle.
                    sceneRuntime.testSceneNotice(1401)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.035)); sceneRuntime.testSceneTick()
                    try check(sceneRuntime.testMotion == .normal, "Duplicate completion resumed old idle")
                    RunLoop.main.run(until: Date().addingTimeInterval(0.08)); sceneRuntime.testSceneTick()
                    try check(sceneRuntime.testMotion == .idle, "Idle did not return after a fresh completion delay")
                    sceneRuntime.testSceneNotice(1327)
                    try check(sceneRuntime.testMissionControl && sceneRuntime.testMotion == .normal && sceneRuntime.testRole == arrow,
                        "System Mission Control entry did not end idle and select the shell role")
                    try check(sceneRuntime.renderedFrame == pictures[0], "Mission Control retained an idle image")
                    let timers = sceneRuntime.testTimerCreations
                    RunLoop.main.run(until: Date().addingTimeInterval(0.18)); sceneRuntime.testSceneTick()
                    try check(sceneRuntime.testMotion == .normal && sceneRuntime.testFrameDeadline == nil,
                        "Mission Control restarted idle before closing")
                    // This fixture has no OS event monitor: the established
                    // 120 Hz counter fallback remains active, without new polls.
                    try check(sceneRuntime.testTimerCreations - timers < 32, "Mission Control created a busy timer loop")
                    sceneRuntime.testSceneNotice(1328)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.035)); sceneRuntime.testSceneTick()
                    try check(!sceneRuntime.testMissionControl && sceneRuntime.testMotion == .normal,
                        "Mission Control exit reused the elapsed idle delay")
                    RunLoop.main.run(until: Date().addingTimeInterval(0.08)); sceneRuntime.testSceneTick()
                    try check(sceneRuntime.testMotion == .idle, "Idle did not return after Mission Control closed")
                }
                sceneRuntime.testScene(true)
                sceneRuntime.testPhysicalDown = true; sceneRuntime.injectObserved(.leftMouseDown)
                try check(sceneRuntime.testMotion == .press, "Shell mouse-down stopped playing")
                sceneRuntime.testSceneNotice(1401)
                try check(sceneRuntime.testMotion == .press, "Space completion cancelled a held click")
                sceneRuntime.testPhysicalDown = false; sceneRuntime.injectObserved(.leftMouseUp)
                try check(sceneRuntime.testMotion == .release, "Space completion lost the matching mouse-up")
            }
            sceneRuntime.testSceneNotice(1401)
            try check(!sceneRuntime.enabled && !sceneRuntime.testMissionControl,
                "A completion after stop revived the runtime")
        }
        print("PASS 2/48-frame idle becomes normal on system Space completion without input events, ignores start guesses, tolerates duplicate completion, waits a fresh delay, keeps Mission Control normal and preserves held clicks/stop")

        let cursor = clip([pictures[0]]), click = clip([pictures[1], pictures[2]], duration: 0.1)
        let theme = GalleryTheme(name: "Unregistered scheduling", roles: [
            CursorRole(id: "com.apple.coregraphics.Arrow", name: "A", clips: ["normal": cursor, "press": click, "hold": cursor, "release": click]),
            CursorRole(id: "com.apple.coregraphics.IBeam", name: "B", clips: ["normal": cursor, "press": click, "hold": cursor, "release": click])])
        let runtime = CursorRuntime(); runtime.testBeginUnregistered(theme)
        defer { runtime.testEndUnregistered() }
        runtime.testActivateShake()
        let renders = runtime.testRenderCalls, timers = runtime.testTimerCreations
        for _ in 0..<1000 { runtime.injectObserved(.mouseMoved) }
        try check(runtime.testRenderCalls == renders, "Every movement still renders a shake image")
        try check(runtime.testTimerCreations - timers == 1, "Movement rearms redundant display timers")
        runtime.testPhysicalDown = true; runtime.injectObserved(.leftMouseDown)
        try check(runtime.testMotion == .press && runtime.testRenderCalls == renders + 1, "Coalescing delayed mouse-down")
        runtime.testPhysicalDown = false; runtime.injectObserved(.leftMouseUp)
        try check(runtime.testMotion == .release && runtime.testRenderCalls == renders + 2, "Coalescing delayed mouse-up")
        let beforeRole = runtime.testRenderCalls
        runtime.testIdentify(["com.apple.coregraphics.IBeam"])
        try check(runtime.testRenderCalls > beforeRole && runtime.testMotion == .normal, "Role changes were coalesced or inherited release")
        print("PASS 1000 shake movements share one timer; button edges and role changes still render immediately")
        var rootChanges = 0, labelChanges = 0
        let rootSubscription = runtime.objectWillChange.sink { rootChanges += 1 }
        let labelSubscription = runtime.statusDisplay.objectWillChange.sink { labelChanges += 1 }
        defer { rootSubscription.cancel(); labelSubscription.cancel() }
        for index in 0..<1000 { runtime.statusDisplay.set("Energy check phase \(index)") }
        runtime.statusDisplay.set("Energy check phase 999")
        try check(rootChanges == 0 && labelChanges == 1000 && runtime.status == "Energy check phase 999",
                  "A status-only update still invalidates the entire runtime view graph")
        print("PASS 1000 status changes update only the label; zero editor/gallery runtime notifications; duplicate text is silent")

        var busy = true, hidden = 0, shown = 0, systemVisible: Int32 = 1
        var io = WaitCursorOverlay.IO()
        io.visibility = { systemVisible }; io.background = { _ in 0 }
        io.hide = { hidden += 1; systemVisible = 0; return .success }
        io.show = { shown += 1; systemVisible = 1; return .success }
        io.owner = { $0 == 0 ? nil : WaitCursorOverlay.Owner(pid: 4242,
            bounds: CGRect(x: -10000, y: -10000, width: 20000, height: 20000)) }
        let overlay = WaitCursorOverlay(io: io), waitID = "com.apple.coregraphics.Wait"
        let overlayRuntime = CursorRuntime(waitOverlay: overlay)
        var busyTheme = theme
        busyTheme.roles.append(CursorRole(id: waitID, name: "Wait", clips: ["normal": click, "press": click, "release": click]))
        overlayRuntime.testBeginUnregistered(busyTheme)
        try overlayRuntime.testAttachWait(waitID, query: { _ in busy })
        overlay.pointerChanged(window: 7)
        try check(overlay.active && overlayRuntime.testRole == waitID && hidden == 1, "Busy signal did not hand over the actual runtime role")
        overlayRuntime.testPhysicalDown = true; overlayRuntime.injectObserved(.leftMouseDown)
        try check(overlayRuntime.testMotion == .press, "Busy overlay lost its independent click phase")
        overlayRuntime.setScale(1.25)
        try check(overlay.testGeometry?.width == 40, "Busy overlay ignores the live theme size")
        overlay.pointerChanged(window: 0)
        overlayRuntime.testIdentify(["com.apple.coregraphics.Arrow"])
        overlayRuntime.testPhysicalDown = false; overlayRuntime.injectObserved(.leftMouseUp)
        try check(!overlay.active && shown == 1 && overlayRuntime.testMotion == .normal,
                  "Leaving the busy window leaked its release into the ordinary role")
        busy = false; overlay.pointerChanged(window: 7)
        try check(!overlay.active && hidden == 1, "Recovered app was hidden again")
        overlayRuntime.testEndUnregistered()
        try check(shown == hidden && !overlay.testHasWatchdog, "Runtime stop retained an overlay hide or timer")
        print("PASS busy runtime handover, click isolation, live size, window exit, recovery and stop; native hide/show are spies")
    }
}
