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
let regression = RegressionTests()
var checks: [(String, () throws -> Void)] = [
    ("material variants preserve edits and portable alternatives", imports.testVariantsPreserveEditsAndArchiveWithoutSourceFiles),
    ("normal loop survives brief cursor-region rebuilds", regression.testNormalLoopSurvivesBriefCursorRegionRebuilds),
    ("counter credits handle delayed callbacks, publication and wrap", regression.testCounterCreditsHandleBothPublicationOrdersAndWrap),
    ("animation deadlines retain sub-polling precision", regression.testAnimationDeadlinesAreNotRoundedToPollingIntervals),
    ("shared drag images prefer primary arrow and link roles", regression.testSharedDragImagesPreferPrimaryRoles),
    ("shake has one smooth monotonic shrink without retrigger", regression.testShakeEnvelopeDoesNotRestartAndShrinksSmoothly),
    ("high-resolution static cursor returns to arrow", regression.testHighResolutionStaticCursorObservation),
    ("duplicate frame runs preserve loop timing", regression.testRepeatedFrameRunsKeepLoopTiming),
    ("per-role idle deadline, archive and legacy defaults", regression.testRoleIdleOverrideArchiveAndLegacy),
    ("Gallery resize corner hysteresis", regression.testResizeCornerHysteresis),
    ("role families isolate link, horizontal and vertical settings", regression.testRoleFamiliesIgnoreNamesAndSeparateSizes),
    ("deliberate shake, ordinary motion and recovery", regression.testDeliberateShakeAndRecovery),
    ("late input keeps event clock and release wins", interaction.testDelayedDeliveryPreservesEventClockAndQuickRelease),
    ("late unsplit click skips expired phases", interaction.testDelayedUnsplitClickSkipsExpiredSegments),
    ("adaptive static, moving and animation wakeups", interaction.testAdaptiveWakeupDeadlines),
    ("persisted thumbnails, invalidation and legacy index", regression.testPersistedThumbnailCacheAndLegacyIndex),
    ("duplicate frame order and frame limit", regression.testDuplicateFrameOrderAndLimit),
    ("role size, native mode and legacy defaults", regression.testRolePresentationArchiveAndLegacyDefaults),
    ("mixing a role preserves target aliases and other roles", regression.testMixedRoleTemplatePreservesTargetAndOtherRoles),
    ("theme directory index and path validation", regression.testThemeDirectoryIndexAndTraversalRejection),
    ("direct bitmap recognizes native versus applied", regression.testDirectBitmapDistinguishesNativeAndApplied),
    ("global animated filmstrip identification", regression.testGlobalAnimationFilmstripObservation),
    ("theme-only scaling preserves hotspots and source", regression.testSizeScalesGeometryAndLeavesSourceUntouched),
    ("release interrupts press", interaction.testReleaseInterruptsPressAndExpires),
    ("new click replaces pending release", interaction.testNewClickReplacesOldReleaseDeadline),
    ("activity cancels idle and held button blocks idle", interaction.testIdleIsCancelledByActivityAndNeverStartsWhileHeld),
    ("disabled interactions", interaction.testDisabledFeaturesDoNotEnterAnimationStates),
    ("cape round-trip, frame order and hotspot", imports.testCapeRoundTripPreservesOrderHotspotsAndSize),
    ("resampling preserves duration", imports.testResamplingPreservesDuration),
    ("invalid geometry and nonfinite timing", imports.testRejectsInvalidGeometryAndNonFiniteTiming),
    ("duplicate roles and malformed PE rejection", imports.testDuplicateRolesAndMalformedPEAreRejected),
    ("CUR decoding and hotspot", imports.testCURHotspotAndPixels),
    ("CUR DIB alpha and bottom-up orientation", imports.testCURDIBAlphaAndBottomUpOrder),
    ("unsplit click completes after quick mouse-up", regression.testUnsplitClickCompletesWithoutHoldOrRelease),
    ("unsplit click automatically plays the release segment", regression.testUnsplitClickAutomaticallyPlaysRelease),
    ("hold assets determine interaction and override legacy switches", regression.testRoleDefaultsAndLegacyMigration),
    ("background quick-click counters and wrap", regression.testPassiveQuickClickAndCounterWrap),
    ("portable archive deduplication and overrides", regression.testArchiveDeduplicatesAndPreservesOverrides),
    ("known-unknown-known cursor recovery", regression.testUnknownDoesNotPoisonLaterKnownMatch)
]
if ProcessInfo.processInfo.environment["GALLERY_PRTS_EXE"] != nil {
    checks.append(("real PRTS resource extraction, ANI and cape conversion", imports.testRealPRTSOptionalIntegration))
} else { print("SKIP real PRTS integration (set GALLERY_PRTS_EXE to a locally downloaded installer)") }
for (name, check) in checks {
    do { try check(); print("PASS \(name)") }
    catch { print("FAIL \(name): \(error)"); exit(1) }
}
print("\(checks.count) checks passed")
