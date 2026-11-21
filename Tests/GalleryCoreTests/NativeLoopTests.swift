import Foundation
import GalleryCore

final class NativeLoopTests {
    func testSparseNormalClipsUseVisibleChangesWithoutSegmentRestarts() {
        // Angelina-style holds: 73 source ticks but only four pose changes.
        let poses = Array(repeating: 0, count: 43) + Array(repeating: 1, count: 6)
            + Array(repeating: 2, count: 6) + Array(repeating: 3, count: 6) + Array(repeating: 0, count: 12)
        let schedule = FrameRunSchedule(poses)
        expectEqual(schedule.visibleChanges, 4)
        expectEqual(schedule.nextChange(after: 0, looping: true), 43)
        expectEqual(schedule.nextChange(after: 61, looping: true), 116)
        expectFalse(NativeLoopWindow.eligible(count: 73, motion: .normal, resize: false, expanded: true,
                                              visibleChanges: schedule.visibleChanges))
        expectEqual(NativeLoopWindow.eligible(count: 73, motion: .normal, resize: false, expanded: true, visibleChanges: 73), true)
        expectEqual(NativeLoopWindow.eligible(count: 25, motion: .normal, resize: false, expanded: true, visibleChanges: 24), true)
        expectEqual(NativeLoopWindow.eligible(count: 12, motion: .normal, resize: false, expanded: true, visibleChanges: 4), true)
        expectEqual(FrameRunSchedule([0, 1, 0, 1]).visibleChanges, 4)
        expectEqual(FrameRunSchedule([0, 0, 0]).visibleChanges, 0)
        expectEqual(FrameRunSchedule([Int]()).visibleChanges, 0)
    }
    func testEligibilityKeepsOneShotAndResizePathsSeparate() {
        for motion in Motion.allCases {
            for count in [2, 24, 25, 72, 240] {
                expectEqual(NativeLoopWindow.eligible(count: count, motion: motion, resize: false, expanded: true), motion.loops && (motion != .idle || count <= 24))
                expectEqual(NativeLoopWindow.eligible(count: count, motion: motion, resize: false, expanded: false), motion == .normal && count <= 24)
                expectFalse(NativeLoopWindow.eligible(count: count, motion: motion, resize: true, expanded: true))
            }
        }
        expectFalse(NativeLoopWindow.eligible(count: 1, motion: .idle, resize: false, expanded: true))
        expectFalse(NativeLoopWindow.eligible(count: 241, motion: .hold, resize: false, expanded: true))
    }
    func testShortLoopsKeepTheEntireRotatedCycle() {
        for count in 2...24 {
            for step in [0, 1, 23, 1007] {
                let window = NativeLoopWindow(sourceCount: count, startStep: step)!
                expectEqual(window.indices, (0..<count).map { (step + $0) % count })
                expectEqual(window.nextStep, nil)
            }
        }
    }
    func testLongWindowsPreserveEverySourceFrameAcrossWraps() {
        for count in [25, 29, 48, 72, 127, 240] {
            var step = 7
            var visible: [Int] = []
            for _ in 0..<100 {
                let window = NativeLoopWindow(sourceCount: count, startStep: step)!
                expectEqual(window.count, 24)
                let next = window.nextStep!
                let following = NativeLoopWindow(sourceCount: count, startStep: next)!
                expectEqual(Array(window.indices.suffix(2)), Array(following.indices.prefix(2)))
                visible += window.indices.prefix(next - step)
                step = next
            }
            expectEqual(visible, (0..<visible.count).map { (7 + $0) % count })
        }
    }
    func testPreparationLeadIsBoundedAndRetainsFrameTiming() {
        for duration in [1.0 / 240, 1.0 / 120, 1.0 / 60, 0.05, 1, 10] {
            let lead = NativeLoopWindow.preparationLead(frameDuration: duration)
            expectEqual((1...12).contains(lead), true)
            expectEqual(Double(lead) * duration >= min(0.04, duration), true)
            let window = NativeLoopWindow(sourceCount: 72, startStep: lead)!
            expectEqual(Double(window.nextStep! - window.startStep) * duration, 22 * duration, accuracy: 0.0000001)
        }
        expectEqual(NativeLoopWindow.preparationLead(frameDuration: .leastNonzeroMagnitude), 12)
        expectEqual(NativeLoopWindow.preparationLead(frameDuration: .nan), 1)
        expectEqual(NativeLoopWindow(sourceCount: 0, startStep: 0), nil)
        expectEqual(NativeLoopWindow(sourceCount: 25, startStep: -1), nil)
    }
}
