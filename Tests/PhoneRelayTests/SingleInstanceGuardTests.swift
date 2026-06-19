import XCTest
@testable import PhoneRelay

/// Covers the duplicate-instance guard (only one Phone Relay may run at a time;
/// the newest copy yields) and the connection-window presentation policy
/// (automatic reconnect cycles must not steal focus from other apps).
final class SingleInstanceGuardTests: XCTestCase {
    @MainActor
    func testAppDelegateExplicitlySupportsSecureRestorableState() {
        let delegate = AppDelegate()

        XCTAssertTrue(delegate.applicationSupportsSecureRestorableState(NSApp))
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

    func testNewerDuplicateYieldsToOlderInstance() {
        let older = instance(pid: 100, launchedAt: 100)
        let newer = instance(pid: 200, launchedAt: 200)

        XCTAssertEqual(
            AppDelegate.blockingDuplicateInstance(candidates: [older, newer], current: newer)?.pid,
            100
        )
    }

    func testOlderInstanceKeepsRunningWhenDuplicateIsNewer() {
        let older = instance(pid: 100, launchedAt: 100)
        let newer = instance(pid: 200, launchedAt: 200)

        XCTAssertNil(AppDelegate.blockingDuplicateInstance(candidates: [older, newer], current: older))
    }

    func testInstanceIsNotItsOwnDuplicate() {
        let only = instance(pid: 100)

        XCTAssertNil(AppDelegate.blockingDuplicateInstance(candidates: [only], current: only))
    }

    func testTerminatedInstancesAreIgnored() {
        let dead = instance(pid: 100, launchedAt: 100, isTerminated: true)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertNil(AppDelegate.blockingDuplicateInstance(candidates: [dead, current], current: current))
    }

    func testUnrelatedAppsAreIgnored() {
        let browser = instance(pid: 100, bundleID: "com.apple.Safari", executableName: "Safari", launchedAt: 50)
        let testRunner = instance(pid: 101, bundleID: nil, executableName: "xctest", launchedAt: 60)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertNil(
            AppDelegate.blockingDuplicateInstance(candidates: [browser, testRunner, current], current: current)
        )
    }

    func testDebugBinaryAndBundledAppCountAsTheSameApp() {
        let debugRun = instance(pid: 100, bundleID: nil, executableName: "PhoneRelayBinary", launchedAt: 100)
        let bundled = instance(pid: 200, executableName: "PhoneRelay", launchedAt: 200)

        XCTAssertEqual(
            AppDelegate.blockingDuplicateInstance(candidates: [debugRun, bundled], current: bundled)?.pid,
            100
        )
    }

    func testDifferentBundleIDsAreDifferentAppsEvenWithSameExecutableName() {
        let impostor = instance(pid: 100, bundleID: "com.other.PhoneRelay", executableName: "PhoneRelay", launchedAt: 50)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertNil(AppDelegate.blockingDuplicateInstance(candidates: [impostor, current], current: current))
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
