import Foundation
import GalleryCore

final class RenderPolicyTests {
    func testRasterGeometryPreservesDisplayGridAndSharesNearbyScales() {
        let clip = CursorClip(frames: [Data([1])], width: 32, height: 24, hotX: 9.333333333333334, hotY: 6.5)
        expectEqual(CursorRasterGeometry(clip, scale: 1.9), CursorRasterGeometry(clip, scale: 1.9001))
        expectFalse(CursorRasterGeometry(clip, scale: 1.9) == CursorRasterGeometry(clip, scale: 2))
        for step in 250...6000 {
            let scale = Double(step) / 1000
            let old = clip.scaled(by: Double(Int((scale * 10000).rounded())) / 10000).alignedToPixels()
            let grid = CursorRasterGeometry(clip, scale: scale)
            expectEqual(grid.applying(to: clip), old)
            expectEqual(grid.rasterBytes(maximumScale: 2), Int(old.width * old.height) * 8 * 5)
        }
        var moved = clip; moved.hotX = 4
        expectFalse(CursorRasterGeometry(clip) == CursorRasterGeometry(moved))
    }

    func testLongLoopBudgetFitsAndHasAHardBound() {
        let geometry = CursorRasterGeometry(CursorClip(frames: [Data([1])]), scale: 1.9)
        let cost = geometry.rasterBytes(maximumScale: 2)
        let active = CursorFrameCacheBudget(uniqueFrames: 228, bytesPerFrame: cost)
        expectEqual(active.retainsActiveClip, true)
        expectGreater(active.count, 228)
        expectGreater(active.bytes, 228 * cost)
        expectEqual(active.bytes <= CursorFrameCacheBudget.maximumBytes, true)
        expectEqual(CursorFrameCacheBudget(uniqueFrames: 4, bytesPerFrame: cost).bytes, CursorFrameCacheBudget.baseBytes)
        let huge = CursorFrameCacheBudget(uniqueFrames: 240, bytesPerFrame: 2_000_000)
        expectFalse(huge.retainsActiveClip)
        expectEqual(huge.bytes, CursorFrameCacheBudget.maximumBytes)
        let overflow = CursorFrameCacheBudget(uniqueFrames: 240, bytesPerFrame: Int.max)
        expectFalse(overflow.retainsActiveClip)
        expectEqual(overflow.bytes, CursorFrameCacheBudget.maximumBytes)
    }

    func testConfirmationMissesBackOffWithoutConcurrentProbes() {
        var retry = CursorConfirmationBackoff()
        retry.synchronize(revision: 1, now: 10)
        var time = 10.0
        for interval in [0.002, 0.004, 0.008, 0.016, 0.016] {
            expectEqual(retry.shouldProbe(seed: 5, now: time), true)
            retry.beginProbe(seed: 5)
            expectFalse(retry.shouldProbe(seed: 6, now: time + 1))
            expectEqual(retry.deadline, nil)
            retry.finishProbe(revision: 1, now: time)
            expectEqual(retry.deadline!, time + interval, accuracy: 0.000001)
            expectFalse(retry.shouldProbe(seed: 5, now: time + interval / 2))
            time = retry.deadline!
        }
    }

    func testNewSeedAndSubmissionBypassConfirmationBackoff() {
        var retry = CursorConfirmationBackoff()
        retry.synchronize(revision: 2, now: 1)
        retry.beginProbe(seed: 8); retry.finishProbe(revision: 2, now: 1)
        expectFalse(retry.shouldProbe(seed: 8, now: 1.001))
        expectEqual(retry.shouldProbe(seed: 9, now: 1.001), true)
        retry.synchronize(revision: 3, now: 1.001)
        expectEqual(retry.shouldProbe(seed: 8, now: 1.001), true)
        retry.finishProbe(revision: 2, now: 9)
        expectEqual(retry.deadline, 1.001)
        retry.synchronize(revision: nil, now: 2)
        expectEqual(retry.deadline, nil)
        expectFalse(retry.shouldProbe(seed: 10, now: 2))
    }

    func testButtonEdgeCanRestartConfirmationImmediately() {
        var retry = CursorConfirmationBackoff()
        retry.synchronize(revision: 7, now: 0)
        retry.beginProbe(seed: 3); retry.finishProbe(revision: 7, now: 0)
        retry.reset(); retry.synchronize(revision: 7, now: 0.0001)
        expectEqual(retry.shouldProbe(seed: 3, now: 0.0001), true)
        // Rechecking the same submission during movement cannot push its
        // existing deadline forward or rearm a finished confirmation.
        let deadline = retry.deadline
        for step in 1...1000 { retry.synchronize(revision: 7, now: Double(step)) }
        expectEqual(retry.deadline, deadline)
        retry.reset()
        expectEqual(retry.deadline, nil)
    }
}
