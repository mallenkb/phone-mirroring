import XCTest
@testable import PhoneRelay

/// Covers the duplicate-instance guard (only one Phone Relay may run at a time;
/// a fresh launch evicts stale older copies) and the connection-window presentation policy
/// (automatic reconnect cycles must not steal focus from other apps).
final class SingleInstanceGuardTests: XCTestCase {
    func testAppDelegateExplicitlySupportsSecureRestorableState() {
        let source = try! String(contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("public func applicationSupportsSecureRestorableState"))
        XCTAssertTrue(source.contains("public func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {\n        false\n    }"))
        XCTAssertTrue(source.contains("public func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {\n        false\n    }"))
    }

    private func instance(
        pid: Int32,
        bundleID: String? = "com.mallenkb.PhoneRelay",
        executableName: String? = "PhoneRelay",
        launchedAt: TimeInterval? = 100,
        isTerminated: Bool = false
    ) -> AppInstanceDescriptor {
        AppInstanceDescriptor(
            pid: pid,
            bundleID: bundleID,
            executableName: executableName,
            launchDate: launchedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
            isTerminated: isTerminated
        )
    }

    // MARK: - Duplicate detection

    func testNewerLaunchTargetsOlderInstanceForEviction() {
        let older = instance(pid: 100, launchedAt: 100)
        let newer = instance(pid: 200, launchedAt: 200)

        XCTAssertEqual(AppDelegate.olderDuplicateInstances(candidates: [older, newer], current: newer).map(\.pid), [100])
    }

    func testOlderLaunchDoesNotTargetNewerInstanceForEviction() {
        let older = instance(pid: 100, launchedAt: 100)
        let newer = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(AppDelegate.olderDuplicateInstances(candidates: [older, newer], current: older).isEmpty)
    }

    func testInstanceIsNotItsOwnDuplicate() {
        let only = instance(pid: 100)

        XCTAssertTrue(AppDelegate.olderDuplicateInstances(candidates: [only], current: only).isEmpty)
    }

    func testTerminatedInstancesAreIgnored() {
        let dead = instance(pid: 100, launchedAt: 100, isTerminated: true)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(AppDelegate.olderDuplicateInstances(candidates: [dead, current], current: current).isEmpty)
    }

    func testUnrelatedAppsAreIgnored() {
        let browser = instance(pid: 100, bundleID: "com.apple.Safari", executableName: "Safari", launchedAt: 50)
        let testRunner = instance(pid: 101, bundleID: nil, executableName: "xctest", launchedAt: 60)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(AppDelegate.olderDuplicateInstances(candidates: [browser, testRunner, current], current: current).isEmpty)
    }

    func testDebugBinaryAndBundledAppCountAsTheSameApp() {
        let debugRun = instance(pid: 100, bundleID: nil, executableName: "PhoneRelayBinary", launchedAt: 100)
        let bundled = instance(pid: 200, executableName: "PhoneRelay", launchedAt: 200)

        XCTAssertEqual(
            AppDelegate.olderDuplicateInstances(candidates: [debugRun, bundled], current: bundled).map(\.pid),
            [100]
        )
    }

    func testDifferentBundleIDsAreDifferentAppsEvenWithSameExecutableName() {
        let impostor = instance(pid: 100, bundleID: "com.other.PhoneRelay", executableName: "PhoneRelay", launchedAt: 50)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(AppDelegate.olderDuplicateInstances(candidates: [impostor, current], current: current).isEmpty)
    }

    // MARK: - Ordering

    func testLaunchDateTieFallsBackToLowerPID() {
        let lowerPID = instance(pid: 100, launchedAt: 100)
        let higherPID = instance(pid: 200, launchedAt: 100)

        XCTAssertTrue(AppDelegate.instancePrecedes(lowerPID, higherPID))
        XCTAssertFalse(AppDelegate.instancePrecedes(higherPID, lowerPID))
    }

    func testKnownLaunchDatePrecedesUnknown() {
        let known = instance(pid: 300, launchedAt: 100)
        let unknown = instance(pid: 100, launchedAt: nil)

        XCTAssertTrue(AppDelegate.instancePrecedes(known, unknown))
        XCTAssertFalse(AppDelegate.instancePrecedes(unknown, known))
    }

    func testBothLaunchDatesUnknownFallsBackToPID() {
        let lower = instance(pid: 100, launchedAt: nil)
        let higher = instance(pid: 200, launchedAt: nil)

        XCTAssertTrue(AppDelegate.instancePrecedes(lower, higher))
        XCTAssertFalse(AppDelegate.instancePrecedes(higher, lower))
    }

    // MARK: - Launch options

    func testBackgroundLaunchFlagDetection() {
        XCTAssertTrue(AppDelegate.isBackgroundLaunch(arguments: ["PhoneRelay", "--launched-in-background"]))
        XCTAssertFalse(AppDelegate.isBackgroundLaunch(arguments: ["PhoneRelay"]))
        XCTAssertFalse(AppDelegate.isBackgroundLaunch(arguments: []))
    }

    // MARK: - Connection window presentation

    func testConnectionWindowOnlyTakesFocusWhenAppIsActive() {
        XCTAssertEqual(AppModel.connectionWindowPresentation(appIsActive: true), .activateAndMakeKey)
        XCTAssertEqual(AppModel.connectionWindowPresentation(appIsActive: false), .orderFrontOnly)
    }
}
