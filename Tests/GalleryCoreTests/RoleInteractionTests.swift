import GalleryCore

final class RoleInteractionTests {
    func testUnsplitPressDoesNotReleaseAnotherRole() {
        var m = RoleInteractionMachine(now: 0)
        m.selectRole("arrow", now: 0)
        m.down(now: 1, pressDuration: 0.3, enabled: true, split: false, releaseDuration: 0.4)
        m.up(now: 1.02, enabled: true)
        m.selectRole("text", now: 1.05)
        m.tick(now: 1.35, idleDelay: 5, idleEnabled: true)
        expectEqual(m.motion, .normal)
        expectEqual(m.transitionDeadline, nil)
        // Returning to the original role continues its own release clock.
        m.selectRole("arrow", now: 1.4)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 1.3, accuracy: 0.00001)
        m.selectRole("text", now: 1.45)
        expectEqual(m.motion, .normal)
        m.selectRole("arrow", now: 2)
        expectEqual(m.motion, .normal)
        expectEqual(m.transitionDeadline, nil)
    }

    func testMouseUpOnlyReleasesTheDownRole() {
        var m = RoleInteractionMachine(now: 0)
        m.selectRole("arrow", now: 0)
        m.down(now: 1, pressDuration: 1, enabled: true, releaseDuration: 0.4)
        m.selectRole("link", now: 1.1)
        expectEqual(m.motion, .normal)
        expectEqual(m.buttonDown, true)
        m.up(now: 1.2, enabled: true)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
        expectEqual(m.transitionDeadline, nil)
        m.selectRole("arrow", now: 1.3)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 1.2)
        expectEqual(m.transitionDeadline!, 1.6, accuracy: 0.00001)
        m.tick(now: 1.61, idleDelay: 5, idleEnabled: true)
        expectEqual(m.motion, .normal)
    }

    func testRoleRoundTripAndAliasesKeepOwnEpoch() {
        var m = RoleInteractionMachine(now: 0)
        m.selectRole("arrow", now: 0)
        m.down(now: 1, pressDuration: 0.1, enabled: true, releaseDuration: 0.5)
        m.selectRole("arrow", now: 1.02)
        expectEqual(m.motionStartedAt, 1)
        m.selectRole("copy", now: 1.04)
        m.tick(now: 1.15, idleDelay: 0, idleEnabled: true)
        expectEqual(m.motion, .normal)
        m.selectRole("arrow", now: 1.2)
        expectEqual(m.motion, .hold)
        expectEqual(m.motionStartedAt, 1.1, accuracy: 0.00001)
        m.up(now: 1.3, enabled: true)
        m.selectRole("copy", now: 1.35)
        expectEqual(m.motion, .normal)
        m.selectRole("arrow", now: 1.4)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 1.3)
        m.up(now: 1.45, enabled: true)
        expectEqual(m.motionStartedAt, 1.3)
    }

    func testNewRoleClickDoesNotOverwritePreviousRole() {
        var m = RoleInteractionMachine(now: 0)
        m.selectRole("arrow", now: 0)
        m.down(now: 1, pressDuration: 0.5, enabled: true, split: false, releaseDuration: 0.6)
        m.up(now: 1.02, enabled: true)
        m.selectRole("link", now: 1.1)
        m.down(now: 1.2, pressDuration: 0.1, enabled: true, releaseDuration: 0.2)
        m.up(now: 1.22, enabled: true)
        expectEqual(m.motion, .release)
        expectEqual(m.transitionDeadline!, 1.42, accuracy: 0.00001)
        m.selectRole("arrow", now: 1.3)
        expectEqual(m.motion, .press)
        expectEqual(m.motionStartedAt, 1)
        m.selectRole("link", now: 1.35)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 1.22)
        m.selectRole("arrow", now: 1.6)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 1.5)
    }

    func testUnknownRoleDoesNotAdoptAnotherClick() {
        var m = RoleInteractionMachine(now: 0)
        m.down(now: 1, pressDuration: nil, enabled: true)
        m.selectRole("text", now: 1.1)
        m.up(now: 1.2, enabled: true)
        expectEqual(m.motion, .normal)
        m.down(now: 2, pressDuration: 0.1, enabled: true, releaseDuration: 0.5)
        m.selectRole(nil, now: 2.05)
        m.up(now: 2.1, enabled: true)
        m.selectRole("text", now: 2.2)
        expectEqual(m.motion, .release)
        expectEqual(m.motionStartedAt, 2.1)
        m.selectRole(nil, now: 3)
        m.selectRole("text", now: 4)
        expectEqual(m.motion, .normal)
    }

    func testResetClearsHiddenTimelinesAndAcceptsNextClick() {
        var m = RoleInteractionMachine(now: 0)
        m.selectRole("arrow", now: 0)
        m.down(now: 1, pressDuration: 5, enabled: true, releaseDuration: 1)
        m.selectRole("text", now: 2)
        m.reset(now: 3)
        m.up(now: 3.1, enabled: true)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
        // Pause/resume may retain the runtime's current role identifier.
        m.down(now: 4, pressDuration: 0.2, enabled: true, releaseDuration: 0.3)
        m.up(now: 4.1, enabled: true)
        expectEqual(m.motion, .release)
        m.selectRole("arrow", now: 4.2)
        expectEqual(m.motion, .normal)
        expectEqual(m.transitionDeadline, nil)
    }

    func testHeldButtonBlocksIdleAcrossRoleSwitches() {
        var m = RoleInteractionMachine(now: 0)
        m.selectRole("arrow", now: 0)
        m.down(now: 1, pressDuration: nil, enabled: true, releaseDuration: 0.3)
        m.selectRole("text", now: 2)
        m.tick(now: 10, idleDelay: 1, idleEnabled: true)
        expectEqual(m.motion, .normal)
        m.up(now: 11, enabled: true)
        m.tick(now: 11.5, idleDelay: 1, idleEnabled: true)
        expectEqual(m.motion, .normal)
        m.tick(now: 12, idleDelay: 1, idleEnabled: true)
        expectEqual(m.motion, .idle)
        m.selectRole("arrow", now: 13)
        expectEqual(m.motion, .normal)
    }

    func testEveryCursorFamilyKeepsClicksIndependent() {
        let families = Set(CursorCatalog.all.map { CursorCatalog.family($0.id) }).sorted()
        for origin in families {
            for destination in families where origin != destination {
                for split in [false, true] {
                    var m = RoleInteractionMachine(now: 0)
                    m.selectRole(origin, now: 0)
                    m.down(now: 1, pressDuration: 0.2, enabled: true, split: split, releaseDuration: 0.4)
                    m.selectRole(destination, now: 1.01)
                    m.up(now: 1.02, enabled: true)
                    for time in [1.03, 1.21, 1.5, 2] {
                        m.tick(now: time, idleDelay: 5, idleEnabled: true)
                        expectEqual(m.motion, .normal)
                        expectEqual(m.transitionDeadline, nil)
                    }
                    m.selectRole(origin, now: 3)
                    expectEqual(m.motion, .normal)
                }
            }
        }
    }
}
