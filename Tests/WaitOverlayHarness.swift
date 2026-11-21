import AppKit
import GalleryCore
import GalleryNative

@main
@MainActor
struct OverlayChecks {
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        var frames: [PreparedFrame] = []
        for gray in [0.2, 0.8] {
            let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            let image = context.makeImage()!
            frames.append(PreparedFrame(image: image, data: try CursorImages.png(image)))
        }
        let clip = PreparedClip(clip: CursorClip(frames: frames.map(\.data), frameDuration: 0.1, width: 16, height: 20, hotX: 3, hotY: 4), frames: frames)
        var busy = false, visibility: Int32 = 1, hides = 0, shows = 0, backgrounds: [Bool] = []
        var backgroundEnabled = false
        var position = CGPoint(x: 150, y: 160), pid: pid_t = 4242
        let bounds = CGRect(x: -10000, y: -10000, width: 20000, height: 20000)
        var hideCode = CGError.success, hideEffective = true
        var native = WaitCursorOverlay.IO()
        native.visibility = { visibility }
        native.background = { backgroundEnabled = $0; backgrounds.append($0); return 0 }
        native.hide = { hides += 1; if hideCode == .success && hideEffective { visibility = 0 }; return hideCode }
        native.show = { shows += 1; visibility = 1; return .success }
        native.position = { position }
        native.refreshRate = { _ in 120 }
        native.owner = { $0 == 0 ? nil : WaitCursorOverlay.Owner(pid: pid, bounds: bounds) }
        let overlay = WaitCursorOverlay(io: native)
        var cleanupDepths: [Int] = []
        overlay.willActivate = {
            cleanupDepths.append(hides - shows)
            backgroundEnabled = false // Real renderer.passThrough releases its flag.
        }
        var edges: [Bool] = []
        overlay.onChange = { edges.append($0) }
        overlay.testStart(clip, query: { _ in busy })
        overlay.pointerChanged(window: 7)
        let initialQueries = overlay.queries
        for _ in 0..<1000 { overlay.pointerChanged(window: 7) }
        check(hides == 0 && shows == 0 && !overlay.testHasWatchdog && overlay.queries == initialQueries,
              "1000 normal movements cause no follow timer, hide or extra responsiveness query")
        busy = true; overlay.refresh()
        check(overlay.active && hides == 1 && shows == 0 && overlay.watchdogStarts == 1, "one successful hide starts one active safety timer")
        check(cleanupDepths == [1], "the native busy layer is hidden before old-role cleanup")
        check(backgroundEnabled && backgrounds.suffix(2) == [true, true], "handover reacquires the shared background flag after ordinary cleanup without another hide")
        let initialPositionChanges = overlay.positionChanges
        for _ in 0..<100 { overlay.refresh() }
        check(hides == 1 && overlay.positionChanges == initialPositionChanges && overlay.watchdogStarts == 1,
              "stationary refresh never re-hides, restarts or repositions")
        let start = ProcessInfo.processInfo.systemUptime
        overlay.present(clip, motion: .normal, scale: 1.25, smooth: true, started: start)
        let playbacks = overlay.playbackChanges
        for _ in 0..<100 { overlay.present(clip, motion: .normal, scale: 1.25, smooth: true, started: start) }
        check(overlay.playbackChanges == playbacks && overlay.testGeometry == CursorRasterGeometry(clip.clip, scale: 1.25),
              "repeated presentation preserves compositor playback and exact native geometry")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let grid = overlay.testGeometry!
        guard let frame = overlay.testPanelFrame else { fatalError("FAIL own panel is not visible in WindowServer metadata") }
        print("HOTSPOT", frame, grid, position)
        check(abs(frame.origin.x - (position.x - grid.hotX)) < 0.6 && abs(frame.origin.y - (position.y - grid.height + grid.hotY)) < 0.6,
              "top-left hotspot is aligned at the pointer with Retina rounding")
        position.x += 10; overlay.pointerChanged(window: 7)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        check(overlay.positionChanges == initialPositionChanges + 2, "movement updates one origin without resetting the animation")
        busy = false; overlay.refresh()
        check(!overlay.active && shows == 1 && !overlay.testHasWatchdog && edges == [true, false], "recovery removes overlay, timer and exactly one hide ticket")
        overlay.refresh(); overlay.stop(); overlay.stop()
        check(shows == 1, "repeated recovery and stop never show a cursor hidden by another app")
        overlay.testStart(clip, query: { _ in true }); visibility = 0; overlay.pointerChanged(window: 7)
        check(!overlay.active && hides == 1 && shows == 1 && !overlay.testHasWatchdog, "pre-existing cursor hiding is respected")
        visibility = 1; overlay.refresh(); overlay.setSuspended(true)
        check(!overlay.active && hides == 2 && shows == 2 && !overlay.testHasWatchdog, "sleep/lock/Space suspension balances ownership")
        overlay.setSuspended(false)
        check(overlay.active && hides == 3, "resume can reacquire only after a fresh busy and visible check")
        overlay.pointerChanged(window: 0)
        check(!overlay.active && shows == 3, "unknown/desktop window immediately restores the native cursor")
        pid = ProcessInfo.processInfo.processIdentifier; overlay.pointerChanged(window: 7)
        check(!overlay.active && hides == 3, "the controller never replaces its own app cursor")
        pid = 4242; overlay.stop(); hideCode = .failure
        let cleanupsBeforeFailure = cleanupDepths.count
        overlay.testStart(clip, query: { _ in true }); overlay.pointerChanged(window: 7); overlay.stop()
        check(hides == 4 && shows == 3 && backgrounds.last == false, "failed hides create no show ticket or persistent background override")
        check(cleanupDepths.count == cleanupsBeforeFailure, "failed hiding leaves the ordinary renderer untouched")
        hideCode = .success; overlay.testStart(clip, query: { _ in true }); overlay.pointerChanged(window: 7)
        overlay.pointerChanged(window: 7); overlay.stop()
        let stoppedPositions = overlay.positionChanges
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        check(shows == 4 && !overlay.active && !overlay.testHasWatchdog && overlay.positionChanges == stoppedPositions,
              "stop cancels queued movement, playback and safety timer")
        overlay.testStart(clip, query: { _ in true }); overlay.pointerChanged(window: 7)
        let beforeMoves = overlay.positionChanges
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        position.x += 1; overlay.pointerChanged(window: 7)
        check(overlay.positionChanges == beforeMoves + 1, "the first eligible movement updates inline without a queued frame of latency")
        for _ in 0..<1000 { position.x += 0.01; overlay.pointerChanged(window: 7) }
        let burstMoves = overlay.positionChanges
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(overlay.positionChanges <= burstMoves + 1, "a burst coalesces to one trailing movement at the display cadence")
        visibility = 1
        let lostHides = hides, lostShows = shows
        overlay.refresh()
        check(!overlay.active && !overlay.testHasWatchdog && shows == lostShows + 1,
              "loss of real hiding removes the overlay and balances only its own ticket")
        for _ in 0..<100 { overlay.refresh(); overlay.pointerChanged(window: 7) }
        check(hides == lostHides && shows == lostShows + 1,
              "visibility loss never piles up hide calls during the same busy visit")
        overlay.pointerChanged(window: 8)
        check(overlay.active && hides == lostHides + 1 && visibility == 0,
              "a new busy visit may acquire one fresh ticket after a visibility failure")
        overlay.stop()
        let ineffectiveHides = hides, ineffectiveShows = shows
        hideEffective = false
        overlay.testStart(clip, query: { _ in true }); overlay.pointerChanged(window: 7)
        check(!overlay.active && !overlay.testHasWatchdog && hides == ineffectiveHides + 1 && shows == ineffectiveShows + 1,
              "a successful hide return without real concealment never displays an overlay")
        overlay.stop()
        print("PASS all overlay ownership and scheduling checks; native hides/shows are spies only")
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL " + message) }
        print("PASS " + message)
    }
}
