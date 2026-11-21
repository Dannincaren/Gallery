import AppKit
import GalleryCore
import GalleryNative

@main @MainActor struct NativeLoopHarness {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL " + message) }; print("PASS " + message)
    }
    static func settle(_ renderer: SystemCursorRenderer) {
        let end = Date().addingTimeInterval(5)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        while renderer.testPendingLoopBuilds > 0 && Date() < end
        checkSilent(renderer.testPendingLoopBuilds == 0, "bounded background preparation timed out")
    }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let ids = ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.IBeam", "com.apple.coregraphics.Wait"]
        let before = ids.compactMap { GLCursorBridge.readCursor($0) as NSDictionary? }
        let pictures: [Data] = try (0..<72).map { index in
            let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: Double(index % 8) / 7, green: Double((index * 3) % 11) / 10,
                blue: Double((index * 7) % 13) / 12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            return try CursorImages.png(context.makeImage()!)
        }
        func clip(_ count: Int) -> CursorClip { CursorClip(frames: Array(pictures.prefix(count)), frameDuration: 1.0 / 60, hotX: 3, hotY: 7) }
        let arrow = ids[0], text = ids[1]
        let sequence = Array(pictures.prefix(24))
        var reordered = sequence
        reordered.swapAt(5, 6)
        let expectedAnimation = CursorAnimationImages(dictionary: try CursorImages.capeDictionary(CursorClip(frames: sequence)))!
        let reorderedAnimation = CursorAnimationImages(dictionary: try CursorImages.capeDictionary(CursorClip(frames: reordered)))!
        check(!expectedAnimation.matches(reorderedAnimation), "equal first/middle/last frames cannot acknowledge a differently ordered strip")
        let roles = [CursorRole(id: arrow, name: "Arrow", clips: ["normal": clip(72), "idle": clip(12), "hold": clip(72)]),
                     CursorRole(id: text, name: "Text", clips: ["normal": clip(72), "hold": clip(72)])]
        let prepared = try PreparedCursors(roles: roles)
        let normal = try CursorImages.capeDictionary(CursorClip(frames: [pictures[0]], hotX: 3, hotY: 7))
        let renderer = SystemCursorRenderer(); renderer.testUnselectedLoops = true
        defer { renderer.stop(restoring: nil) }
        renderer.configureNativeNormals([arrow: normal, text: normal], independentRoles: true)
        let idle = prepared.clip(role: arrow, motion: .idle)!
        check(!renderer.testPresentNativeLoop(idle, role: arrow, motion: .idle, started: 100, now: 100), "cold loop immediately keeps the paired-frame fallback")
        check(renderer.testPendingLoopBuilds <= 2, "native preparation has at most two bounded jobs")
        settle(renderer)
        check(renderer.testPresentNativeLoop(idle, role: arrow, motion: .idle, started: 100, now: 100.050001), "short idle switches at the prepared source-frame boundary")
        check(renderer.nextFrameDeadline == nil, "short idle needs no per-frame deadline")
        let shortSubmissions = renderer.submissions
        for index in 0..<1000 {
            checkSilent(renderer.testPresentNativeLoop(idle, role: arrow, motion: .idle, started: 100, now: 100.06 + Double(index) / 120), "short loop lost ownership")
        }
        check(renderer.submissions == shortSubmissions, "1000 short-loop observations never resubmit or restart the animation")
        check(renderer.frameRecords.last?["motion"] as? String == "idle", "native resource retains its actual motion identity")
        check(!renderer.testPresentNativeLoop(idle, role: arrow, motion: .press, started: 110, now: 110)
            && !renderer.testPresentNativeLoop(idle, role: arrow, motion: .release, started: 110, now: 110), "press and release never enter native looping")

        let hold = prepared.clip(role: arrow, motion: .hold)!
        _ = renderer.testPresentNativeLoop(hold, role: arrow, motion: .hold, started: 200, now: 200)
        settle(renderer)
        check(renderer.testPresentNativeLoop(hold, role: arrow, motion: .hold, started: 200, now: 200.050001), "long hold uses a prepared bounded strip")
        let oldSegmentSeed = Int32.max - 991
        _ = renderer.confirmDisplayed(seed: oldSegmentSeed, revision: renderer.imageRevision)
        var step = 3
        for _ in 0..<40 {
            let expected = 200 + Double(step + 22) / 60
            checkSilent(abs(renderer.nextFrameDeadline! - expected) < 0.000001, "segment deadline drifted from the source clock")
            settle(renderer); step += 22
            checkSilent(renderer.testPresentNativeLoop(hold, role: arrow, motion: .hold, started: 200, now: 200 + Double(step) / 60 + 0.000001), "prepared segment missing")
            checkSilent(renderer.testNativeLoopBytes <= CursorFrameCacheBudget.maximumBytes && renderer.testNativeLoopCount <= 16, "native cache grew beyond its bound")
            checkSilent(!renderer.owns(seed: oldSegmentSeed), "an old segment seed acknowledges the current segment")
        }
        check(renderer.frameRecords.filter { $0["segmented"] as? Bool == true }.count == 41, "long hold advances once per 22 source frames across many wraps")
        let resource = GLCursorBridge.readCursor(renderer.testNativeLoopIdentifiers[0])!
        check((resource["FrameCount"] as? NSNumber)?.intValue ?? 0 <= 24, "actual private native resource never exceeds 24 frames")
        let count = (resource["FrameCount"] as! NSNumber).intValue
        let width = (resource["PointsWide"] as! NSNumber).doubleValue
        let height = (resource["PointsHigh"] as! NSNumber).doubleValue
        let image = try CursorImages.bitmap((resource["Representations"] as! [Data]).last!)
        let animation = CursorAnimationImages(dictionary: resource)!
        let observed = CursorAnimationImages.observation(image: image, size: CGSize(width: width, height: height * Double(count)), hotSpot: CGPoint(x: 3, y: 7), count: count)!
        check(animation.matches(observed), "native-strip observations share one sample bank without changing frame order")
        let recovery = renderer.nativeRecoveryImages
        check(recovery?.loops.contains(where: { $0.role == arrow }) == true, "cached native strips remain identifiable after phase changes and cache eviction")
        check(renderer.frameRecords.allSatisfy { $0["global"] as? Bool == false }, "all graphics checks remain unselected and connection-local")

        let late = 200 + Double(step + 27) / 60 + 0.000001
        check(!renderer.testPresentNativeLoop(hold, role: arrow, motion: .hold, started: 200, now: late), "a late wakeup falls back instead of replaying an expired segment")
        settle(renderer)
        check(!renderer.testPresentNativeLoop(hold, role: text, motion: .hold, started: 300, now: 300), "another role has an independent playback clock")
        settle(renderer)
        check(renderer.testPresentNativeLoop(hold, role: text, motion: .hold, started: 300, now: 300.050001), "another role can reuse image bytes without sharing its timeline")
        let textRecord = renderer.frameRecords.last!
        check(textRecord["role"] as? String == text && textRecord["index"] as? Int == 3, "role re-entry starts at that role's requested phase")
        renderer.expandedNativePlayback = false
        check(!renderer.testPresentNativeLoop(hold, role: arrow, motion: .hold, started: 400, now: 400), "compatibility mode preserves the old eligibility")
        renderer.expandedNativePlayback = true
        let idleStart = renderer.frameRecords.count
        for index in 0..<240 {
            renderer.present(hold, role: arrow, motion: .idle, scale: 1, started: 600,
                             now: 600 + Double(index) / 60 + 0.000001, synchronizeRegistration: true)
        }
        let idleRecords = Array(renderer.frameRecords.dropFirst(idleStart))
        check(idleRecords.count == 240 && idleRecords.allSatisfy { $0["nativePaired"] as? Bool == true }
              && idleRecords.enumerated().allSatisfy { $0.element["index"] as? Int == $0.offset % 72 },
              "long idle keeps exact source order across repeated cycles without native-strip handovers")
        let sparseFrames = Array(repeating: pictures[0], count: 43) + Array(repeating: pictures[1], count: 6)
            + Array(repeating: pictures[2], count: 6) + Array(repeating: pictures[3], count: 6) + Array(repeating: pictures[0], count: 12)
        let sparseRole = CursorRole(id: arrow, name: "Held poses", clips: ["normal": CursorClip(frames: sparseFrames, frameDuration: 2.4 / 73, hotX: 3, hotY: 7)])
        let sparse = try PreparedCursors(roles: [sparseRole]).clip(role: arrow, motion: .normal)!
        let sparseStart = renderer.frameRecords.count
        for tick in 0..<600 {
            let elapsed = Double(tick) * 0.0167
            renderer.present(sparse, role: arrow, motion: .normal, scale: 1, started: 900,
                             now: 900 + elapsed, synchronizeRegistration: true)
            let index = Int(elapsed / sparse.clip.frameDuration) % sparse.frames.count
            checkSilent(renderer.displayedFrame == sparse.frames[index].data, "held pose drifted from its source clock")
        }
        let sparseRecords = Array(renderer.frameRecords.dropFirst(sparseStart))
        check(!sparseRecords.isEmpty && sparseRecords.allSatisfy { $0["nativePaired"] as? Bool == true }
              && sparseRecords.count < 25, "73-tick held poses update only at visible changes; no partial native loop can restart")
        _ = renderer.testPresentNativeLoop(hold, role: arrow, motion: .hold, scale: 4, started: 500, now: 500)
        renderer.stop(restoring: nil); settle(renderer)
        check(renderer.testNativeLoopCount == 0 && renderer.testPendingLoopBuilds == 0, "stop discards in-flight background results and private native resources")
        let after = ids.compactMap { GLCursorBridge.readCursor($0) as NSDictionary? }
        if before != after {
            for (index, id) in ids.enumerated() where index < before.count && index < after.count && before[index] != after[index] {
                let keys = before[index].allKeys.compactMap { $0 as? String }.filter {
                    (before[index][$0] as? NSObject)?.isEqual(after[index][$0]) != true
                }
                print("Reference changed during test: \(id), keys: \(keys.sorted()). Stop other cursor software before retesting.")
            }
        }
        check(before == after, "Arrow, IBeam and the original Wait resource are unchanged")
        print("PASS native-loop integration; no global registration, selection or cursor hiding")
    }
    static func checkSilent(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL " + message) }
    }
}
