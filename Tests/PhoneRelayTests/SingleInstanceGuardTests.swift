import XCTest
@testable import PhoneRelay

/// Covers the duplicate-instance guard (only one PhoneRelay may run at a time;
/// the newest copy takes over and older siblings are terminated) and the
/// connection-window presentation policy (automatic reconnect cycles must not
/// steal focus from other apps).
final class SingleInstanceGuardTests: XCTestCase {
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

    // MARK: - Takeover target selection

    func testNewerLaunchTakesOverAllOlderSiblings() {
        let oldest = instance(pid: 100, launchedAt: 100)
        let older = instance(pid: 150, launchedAt: 150)
        let newest = instance(pid: 200, launchedAt: 200)

        XCTAssertEqual(
            AppDelegate.staleSiblingInstances(candidates: [oldest, older, newest], current: newest).map(\.pid),
            [100, 150]
        )
        XCTAssertNil(AppDelegate.newerSiblingInstance(candidates: [oldest, older, newest], current: newest))
    }

    func testOlderInstanceDefersToNewerLaunch() {
        let older = instance(pid: 100, launchedAt: 100)
        let newer = instance(pid: 200, launchedAt: 200)

        XCTAssertEqual(
            AppDelegate.newerSiblingInstance(candidates: [older, newer], current: older)?.pid,
            200
        )
        XCTAssertTrue(AppDelegate.staleSiblingInstances(candidates: [older, newer], current: older).isEmpty)
    }

    func testInstanceIsNotItsOwnSibling() {
        let only = instance(pid: 100)

        XCTAssertTrue(AppDelegate.staleSiblingInstances(candidates: [only], current: only).isEmpty)
        XCTAssertNil(AppDelegate.newerSiblingInstance(candidates: [only], current: only))
    }

    func testTerminatedInstancesAreIgnored() {
        let dead = instance(pid: 100, launchedAt: 100, isTerminated: true)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(AppDelegate.staleSiblingInstances(candidates: [dead, current], current: current).isEmpty)
    }

    func testUnrelatedAppsAreIgnored() {
        let browser = instance(pid: 100, bundleID: "com.apple.Safari", executableName: "Safari", launchedAt: 50)
        let testRunner = instance(pid: 101, bundleID: nil, executableName: "xctest", launchedAt: 60)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(
            AppDelegate.staleSiblingInstances(candidates: [browser, testRunner, current], current: current).isEmpty
        )
        XCTAssertNil(
            AppDelegate.newerSiblingInstance(candidates: [browser, testRunner], current: instance(pid: 90, launchedAt: 10))
        )
    }

    func testDebugBinaryAndBundledAppCountAsTheSameApp() {
        let debugRun = instance(pid: 100, bundleID: nil, executableName: "PhoneRelayBinary", launchedAt: 100)
        let bundled = instance(pid: 200, executableName: "PhoneRelay", launchedAt: 200)

        XCTAssertEqual(
            AppDelegate.staleSiblingInstances(candidates: [debugRun, bundled], current: bundled).map(\.pid),
            [100]
        )
    }

    func testDifferentBundleIDsAreDifferentAppsEvenWithSameExecutableName() {
        let impostor = instance(pid: 100, bundleID: "com.other.PhoneRelay", executableName: "PhoneRelay", launchedAt: 50)
        let current = instance(pid: 200, launchedAt: 200)

        XCTAssertTrue(AppDelegate.staleSiblingInstances(candidates: [impostor, current], current: current).isEmpty)
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
