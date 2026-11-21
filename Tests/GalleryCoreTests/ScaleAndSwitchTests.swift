import Foundation
import GalleryCore

final class ScaleAndSwitchTests {
    private func role(_ width: Double, _ height: Double, scale: Double = 1) -> CursorRole {
        CursorRole(id: "com.apple.coregraphics.Arrow", name: "Arrow", clips: ["normal": CursorClip(frames: [Data([1])], width: width, height: height)], scale: scale)
    }
    func testScaleBoundsFollowGeometryAndBothFactors() {
        var r = role(64, 32, scale: 2)
        let overall = CursorScaleLimits(roles: [r], appearance: CursorAppearance(), themeScale: 1)
        expectEqual(overall.range, 0.25...1); expectEqual(overall.clamp(3), 1)
        let individual = CursorScaleLimits(roles: [r], appearance: CursorAppearance(), themeScale: 2, roleID: r.id)
        expectEqual(individual.range, 0.25...1); expectEqual(individual.clamp(-4), 0.25)
        r.clips["press"] = CursorClip(frames: [Data([2])], width: 128, height: 32)
        expectEqual(CursorScaleLimits(roles: [r], appearance: CursorAppearance(), themeScale: 1).range, 0.25...0.5)
        let tiny = CursorScaleLimits(roles: [role(2, 2, scale: 0.25)], appearance: CursorAppearance(), themeScale: 1)
        expectEqual(tiny.range, 2...3); expectEqual(tiny.clamp(0.25), 2)
        let thin = role(128, 1)
        let fixed = CursorScaleLimits(roles: [thin], appearance: CursorAppearance(), themeScale: 3, roleID: thin.id)
        expectFalse(fixed.conflicting); expectEqual(fixed.range.lowerBound, fixed.range.upperBound)
        let shadow = CursorScaleLimits(roles: [role(64, 32)], appearance: CursorAppearance(shadow: true), themeScale: 1)
        expectEqual(shadow.range.upperBound, 128.0 / 72)
        var native = role(128, 1); native.usesNative = true
        expectEqual(CursorScaleLimits(roles: [native], appearance: CursorAppearance(), themeScale: 1).range, 0.25...3)
        let conflict = CursorScaleLimits(roles: [role(128, 1), role(2, 2, scale: 0.25)], appearance: CursorAppearance(), themeScale: 1)
        expectEqual(conflict.conflicting, true)
        expectFalse(conflict.range.isEmpty)
    }
    func testDirectionalSwitchGateDoesNotExtendOnRepeatedClicks() {
        var gate = ThemeSwitchCooldown()
        expectEqual(gate.begin(.activate, at: 10), true)
        for _ in 0..<500 { expectFalse(gate.begin(.deactivate, at: 11)) }
        expectEqual(gate.deadline, 14); expectFalse(gate.permits(at: 13.999))
        expectEqual(gate.begin(.deactivate, at: 14), true); expectEqual(gate.deadline, 15)
        expectFalse(gate.begin(.activate, at: 14.999))
        expectEqual(gate.begin(.activate, at: 15), true); expectEqual(gate.deadline, 19)
        expectFalse(gate.begin(.activate, at: .nan)); expectEqual(gate.deadline, 19)
    }
}
