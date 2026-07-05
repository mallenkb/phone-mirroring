import XCTest
@testable import PhoneRelay

/// Pins the guards on the stale-adb-daemon remedy (INVARIANTS.md rules 1,
/// 8, 9): the respawn must never fire while mirror work or pairing is live,
/// never re-entrantly, and automatic triggers respect the cooldown while the
/// user's Fix Connection press bypasses only the cooldown — never the
/// mirror-safety guards.
final class ADBDaemonRecoveryTests: XCTestCase {
    private func allowed(
        isMirroring: Bool = false,
        hasMirrorSession: Bool = false,
        hasMirrorLaunchTask: Bool = false,
        isPairing: Bool = false,
        inFlight: Bool = false,
        lastAttemptAt: Date? = nil,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        AppModel.shouldAttemptADBDaemonRecovery(
            isMirroring: isMirroring,
            hasMirrorSession: hasMirrorSession,
            hasMirrorLaunchTask: hasMirrorLaunchTask,
            isPairing: isPairing,
            inFlight: inFlight,
            lastAttemptAt: lastAttemptAt,
            now: now,
            force: force
        )
    }

    func testIdleAppAllowsRecovery() {
        XCTAssertTrue(allowed())
    }

    func testAnyLiveMirrorWorkBlocksRecoveryEvenWhenForced() {
        XCTAssertFalse(allowed(isMirroring: true))
        XCTAssertFalse(allowed(hasMirrorSession: true))
        XCTAssertFalse(allowed(hasMirrorLaunchTask: true))
        XCTAssertFalse(allowed(isPairing: true))
        // Force is the user's cooldown bypass, not a mirror-safety bypass.
        XCTAssertFalse(allowed(isMirroring: true, force: true))
        XCTAssertFalse(allowed(hasMirrorSession: true, force: true))
        XCTAssertFalse(allowed(hasMirrorLaunchTask: true, force: true))
        XCTAssertFalse(allowed(isPairing: true, force: true))
    }

    func testReentrancyIsBlockedEvenWhenForced() {
        XCTAssertFalse(allowed(inFlight: true))
        XCTAssertFalse(allowed(inFlight: true, force: true))
    }

    func testAutomaticRecoveryRespectsCooldownButForceBypassesIt() {
        let now = Date()
        let recent = now.addingTimeInterval(-AppModel.adbDaemonRecoveryCooldown / 2)
        XCTAssertFalse(allowed(lastAttemptAt: recent, now: now))
        XCTAssertTrue(allowed(lastAttemptAt: recent, now: now, force: true))

        let stale = now.addingTimeInterval(-AppModel.adbDaemonRecoveryCooldown - 1)
        XCTAssertTrue(allowed(lastAttemptAt: stale, now: now))
    }

    func testReachableNoRouteSignatureDefaultsFalse() {
        // The attribution signature must never be assumed — only readiness
        // probes that actually saw port-open + adb-no-route set it.
        let readiness = AppModel.WirelessTargetReadiness(
            isReady: false,
            connectAttempts: 3,
            noRouteToHostFailures: 3
        )
        XCTAssertFalse(readiness.sawReachableNoRoute)
        XCTAssertTrue(readiness.sawNoRouteToHost)
    }
}
