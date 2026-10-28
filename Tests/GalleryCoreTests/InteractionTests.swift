import GalleryCore

final class InteractionTests {
    func testDelayedDeliveryPreservesEventClockAndQuickRelease() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 0.1, enabled: true)
        m.tick(now: 1.18, idleDelay: 8, idleEnabled: false)
        expectEqual(m.motion, .hold)
        expectEqual(m.motionStartedAt, 1.1, accuracy: 0.00001)
        // The up event may have occurred before the delayed callback ran.
        m.up(now: 1.04, releaseDuration: 0.2, enabled: true)
        m.tick(now: 1.18, idleDelay: 8, idleEnabled: false)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 1.04)
        m.tick(now: 1.4, idleDelay: 8, idleEnabled: false)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
        expectEqual(m.motionStartedAt, 1.24, accuracy: 0.00001)
        m.tick(now: 12, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motionStartedAt, m.lastActivity + 8)
    }
    func testDelayedUnsplitClickSkipsExpiredSegments() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 0.1, enabled: true, split: false, releaseDuration: 0.2)
        m.up(now: 1.02, releaseDuration: 0.2, enabled: true)
        m.tick(now: 1.5, idleDelay: 8, idleEnabled: false)
        expectEqual(m.motion, .normal)
        expectEqual(m.motionStartedAt, 1.3, accuracy: 0.00001)
        expectEqual(m.transitionDeadline, nil)
    }
    func testAdaptiveWakeupDeadlines() {
        func delay(polling: Bool = false, paused: Bool = false,
                   frame: Double? = nil, transition: Double? = nil, idle: Double? = nil) -> Double {
            PointerSchedule.delay(now: 10, polling: polling, paused: paused,
                                  frameDeadline: frame, transitionDeadline: transition, idleDeadline: idle)
        }
        expectEqual(delay(), 0.2)
        expectEqual(delay(polling: true), 1.0 / 120)
        expectEqual(delay(paused: true, frame: 10.01), 1)
        expectEqual(delay(frame: 10.05), 0.05, accuracy: 0.00001)
        expectEqual(delay(transition: 10.04, idle: 10.02), 0.02, accuracy: 0.00001)
    }
    func testReleaseInterruptsPressAndExpires() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 1, enabled: true)
        expectEqual(m.motion, .press)
        m.up(now: 1.1, releaseDuration: 0.3, enabled: true)
        expectEqual(m.motion, .release)
        m.tick(now: 1.41, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
    }
    func testNewClickReplacesOldReleaseDeadline() {
        var m = InteractionMachine(now: 0)
        m.down(now: 0, pressDuration: 0.2, enabled: true)
        m.up(now: 0.1, releaseDuration: 0.8, enabled: true)
        m.down(now: 0.2, pressDuration: 0.3, enabled: true)
        m.tick(now: 0.51, idleDelay: 2, idleEnabled: true)
        expectEqual(m.motion, .hold)
        m.tick(now: 1, idleDelay: 2, idleEnabled: true)
        expectEqual(m.motion, .hold)
    }
    func testIdleIsCancelledByActivityAndNeverStartsWhileHeld() {
        var m = InteractionMachine(now: 0)
        m.tick(now: 5, idleDelay: 5, idleEnabled: true)
        expectEqual(m.motion, .idle)
        m.activity(now: 5.1)
        expectEqual(m.motion, .normal)
        m.down(now: 6, pressDuration: nil, enabled: true)
        m.tick(now: 60, idleDelay: 5, idleEnabled: true)
        expectEqual(m.motion, .hold)
        m.reset(now: 61)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
    }
    func testDisabledFeaturesDoNotEnterAnimationStates() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 1, enabled: false)
        m.up(now: 2, releaseDuration: 1, enabled: false)
        m.tick(now: 100, idleDelay: 5, idleEnabled: false)
        expectEqual(m.motion, .normal)
    }
}
