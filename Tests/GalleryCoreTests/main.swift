import Foundation

// Standalone checks intentionally work with Command Line Tools; full Xcode and
// XCTest are not required to build or verify Gallery.
func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Expected \(lhs) == \(rhs)", file: file, line: line)
}
func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    precondition(abs(lhs - rhs) <= accuracy, "Expected \(lhs) ≈ \(rhs)", file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, file: file, line: line) }
func expectGreater<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) { precondition(lhs > rhs, file: file, line: line) }
func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { precondition(value != nil, file: file, line: line) }
func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    preconditionFailure("Expected an error", file: file, line: line)
}
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "GalleryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required value missing"]) }
    return value
}
let interaction = InteractionTests(), imports = ImportTests()
var checks: [(String, () throws -> Void)] = [
    ("release interrupts press", interaction.testReleaseInterruptsPressAndExpires),
    ("new click replaces pending release", interaction.testNewClickReplacesOldReleaseDeadline),
    ("activity cancels idle and held button blocks idle", interaction.testIdleIsCancelledByActivityAndNeverStartsWhileHeld),
    ("disabled interactions", interaction.testDisabledFeaturesDoNotEnterAnimationStates),
    ("cape round-trip, frame order and hotspot", imports.testCapeRoundTripPreservesOrderHotspotsAndSize),
    ("resampling preserves duration", imports.testResamplingPreservesDuration),
    ("invalid geometry and nonfinite timing", imports.testRejectsInvalidGeometryAndNonFiniteTiming),
    ("duplicate roles and malformed PE rejection", imports.testDuplicateRolesAndMalformedPEAreRejected),
    ("CUR decoding and hotspot", imports.testCURHotspotAndPixels),
    ("CUR DIB alpha and bottom-up orientation", imports.testCURDIBAlphaAndBottomUpOrder)
]
if ProcessInfo.processInfo.environment["GALLERY_PRTS_EXE"] != nil {
    checks.append(("real PRTS resource extraction, ANI and cape conversion", imports.testRealPRTSOptionalIntegration))
} else { print("SKIP real PRTS integration (set GALLERY_PRTS_EXE to a locally downloaded installer)") }
for (name, check) in checks {
    do { try check(); print("PASS \(name)") }
    catch { print("FAIL \(name): \(error)"); exit(1) }
}
print("\(checks.count) checks passed")
