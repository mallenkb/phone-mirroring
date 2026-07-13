import XCTest
@testable import PhoneRelay

@MainActor
final class ConnectionCoordinatorTests: XCTestCase {
    func testCancelAllCancelsAndClearsEveryOwnedTask() {
        let coordinator = ConnectionCoordinator()
        let tasks = (0..<10).map { _ in Task<Void, Never> { await Task.yield() } }
        coordinator.deviceWatcherTask = tasks[0]
        coordinator.qrPairingTask = tasks[1]
        coordinator.usbConnectTask = tasks[2]
        coordinator.usbWiFiAddressPrefillTask = tasks[3]
        coordinator.usbWiFiHandoffTask = tasks[4]
        coordinator.usbWiFiTakeoverTask = tasks[5]
        coordinator.wirelessStartTask = tasks[6]
        coordinator.reconnectTask = tasks[7]
        coordinator.disconnectRecoveryTask = tasks[8]
        coordinator.automaticReconnectTask = tasks[9]

        coordinator.cancelAll()

        XCTAssertTrue(tasks.allSatisfy(\.isCancelled))
        XCTAssertNil(coordinator.deviceWatcherTask)
        XCTAssertNil(coordinator.qrPairingTask)
        XCTAssertNil(coordinator.usbConnectTask)
        XCTAssertNil(coordinator.usbWiFiAddressPrefillTask)
        XCTAssertNil(coordinator.usbWiFiHandoffTask)
        XCTAssertNil(coordinator.usbWiFiTakeoverTask)
        XCTAssertNil(coordinator.wirelessStartTask)
        XCTAssertNil(coordinator.reconnectTask)
        XCTAssertNil(coordinator.disconnectRecoveryTask)
        XCTAssertNil(coordinator.automaticReconnectTask)
        XCTAssertFalse(coordinator.hasActiveConnectionAttempt)
        XCTAssertFalse(coordinator.hasWirelessWorkInFlight)
    }

    func testWirelessReconnectCancellationPreservesIndependentWork() {
        let coordinator = ConnectionCoordinator()
        let watcher = Task<Void, Never> { await Task.yield() }
        let pairing = Task<Void, Never> { await Task.yield() }
        let usbConnect = Task<Void, Never> { await Task.yield() }
        let handoff = Task<Void, Never> { await Task.yield() }
        let reconnect = Task<Void, Never> { await Task.yield() }
        let wirelessStart = Task<Void, Never> { await Task.yield() }
        let recovery = Task<Void, Never> { await Task.yield() }
        let takeover = Task<Void, Never> { await Task.yield() }
        coordinator.deviceWatcherTask = watcher
        coordinator.qrPairingTask = pairing
        coordinator.usbConnectTask = usbConnect
        coordinator.usbWiFiHandoffTask = handoff
        coordinator.reconnectTask = reconnect
        coordinator.wirelessStartTask = wirelessStart
        coordinator.disconnectRecoveryTask = recovery
        coordinator.usbWiFiTakeoverTask = takeover

        coordinator.cancelWirelessReconnectWork()

        XCTAssertFalse(watcher.isCancelled)
        XCTAssertFalse(pairing.isCancelled)
        XCTAssertFalse(usbConnect.isCancelled)
        XCTAssertFalse(handoff.isCancelled)
        XCTAssertTrue(reconnect.isCancelled)
        XCTAssertTrue(wirelessStart.isCancelled)
        XCTAssertTrue(recovery.isCancelled)
        XCTAssertTrue(takeover.isCancelled)
        XCTAssertNotNil(coordinator.deviceWatcherTask)
        XCTAssertNotNil(coordinator.qrPairingTask)
        XCTAssertNotNil(coordinator.usbConnectTask)
        XCTAssertNotNil(coordinator.usbWiFiHandoffTask)
        XCTAssertNil(coordinator.reconnectTask)
        XCTAssertNil(coordinator.wirelessStartTask)
        XCTAssertNil(coordinator.disconnectRecoveryTask)
        XCTAssertNil(coordinator.usbWiFiTakeoverTask)
        XCTAssertTrue(coordinator.isPreparingWiFiHandoff)

        watcher.cancel()
        pairing.cancel()
        usbConnect.cancel()
        handoff.cancel()
    }

    func testActivityQueriesReflectTaskOwnership() {
        let coordinator = ConnectionCoordinator()
        XCTAssertFalse(coordinator.hasActiveConnectionAttempt)
        XCTAssertFalse(coordinator.hasWirelessWorkInFlight)
        XCTAssertFalse(coordinator.isPreparingWiFiHandoff)

        coordinator.usbConnectTask = Task { await Task.yield() }
        XCTAssertTrue(coordinator.hasActiveConnectionAttempt)
        XCTAssertFalse(coordinator.hasWirelessWorkInFlight)

        coordinator.usbWiFiHandoffTask = Task { await Task.yield() }
        XCTAssertTrue(coordinator.hasWirelessWorkInFlight)
        XCTAssertTrue(coordinator.isPreparingWiFiHandoff)

        coordinator.cancelAll()
    }

    func testResetClearsConnectionRuntimeState() {
        let coordinator = ConnectionCoordinator()
        coordinator.isAutoReconnectSuppressedForManualDisconnect = true
        coordinator.manualDisconnectKnownSerials = ["USB-1"]
        coordinator.failedAutoConnectTargets = ["192.0.2.1:5555": Date()]
        coordinator.autoConnectTargetsInFlight = ["192.0.2.1:5555"]
        coordinator.wirelessPinnedUSBSerials = ["USB-1"]
        coordinator.manualUSBPinnedSerials = ["USB-1"]
        coordinator.launchReconnectDeadline = Date()
        coordinator.failedLegacyHandoffSerials = ["USB-1"]

        coordinator.reset()

        XCTAssertFalse(coordinator.isAutoReconnectSuppressedForManualDisconnect)
        XCTAssertNil(coordinator.manualDisconnectKnownSerials)
        XCTAssertTrue(coordinator.failedAutoConnectTargets.isEmpty)
        XCTAssertTrue(coordinator.autoConnectTargetsInFlight.isEmpty)
        XCTAssertTrue(coordinator.wirelessPinnedUSBSerials.isEmpty)
        XCTAssertTrue(coordinator.manualUSBPinnedSerials.isEmpty)
        XCTAssertNil(coordinator.launchReconnectDeadline)
        XCTAssertTrue(coordinator.failedLegacyHandoffSerials.isEmpty)
        XCTAssertEqual(coordinator.automaticReconnectState, .idle)
        XCTAssertTrue(coordinator.automaticRetryStates.isEmpty)
    }

    func testAutomaticReconnectBackoffUsesFiveTenTwentyThirtySchedule() {
        XCTAssertEqual(ConnectionCoordinator.automaticReconnectDelay(failureCount: 0), 0)
        XCTAssertEqual(ConnectionCoordinator.automaticReconnectDelay(failureCount: 1), 5)
        XCTAssertEqual(ConnectionCoordinator.automaticReconnectDelay(failureCount: 2), 10)
        XCTAssertEqual(ConnectionCoordinator.automaticReconnectDelay(failureCount: 3), 20)
        XCTAssertEqual(ConnectionCoordinator.automaticReconnectDelay(failureCount: 4), 30)
        XCTAssertEqual(ConnectionCoordinator.automaticReconnectDelay(failureCount: 20), 30)
    }

    func testRetryHistoryIsPhoneKeyedAndRouteEvidenceBypassesOnce() {
        let coordinator = ConnectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = coordinator.recordAutomaticReconnectFailure(
            recordID: "phone-a",
            failure: .temporarilyUnavailable,
            now: now
        )

        XCTAssertFalse(coordinator.mayAttemptAutomaticReconnect(recordID: "phone-a", trigger: .watcher, now: now))
        XCTAssertTrue(coordinator.mayAttemptAutomaticReconnect(recordID: "phone-a", trigger: .discovery(address: "192.0.2.10:37123", eventID: 1), now: now))
        XCTAssertFalse(coordinator.mayAttemptAutomaticReconnect(recordID: "phone-a", trigger: .discovery(address: "192.0.2.10:37123", eventID: 1), now: now))
        XCTAssertTrue(coordinator.mayAttemptAutomaticReconnect(recordID: "phone-b", trigger: .watcher, now: now))
    }

    func testWatcherCannotBypassLegacyDeadlineButFreshDiscoveryCanOnce() {
        let coordinator = ConnectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let legacyDeadline = now.addingTimeInterval(20)

        XCTAssertFalse(
            coordinator.mayAttemptAutomaticReconnect(
                recordID: "phone-a",
                trigger: .watcher,
                now: now,
                notBefore: legacyDeadline
            )
        )
        XCTAssertTrue(
            coordinator.mayAttemptAutomaticReconnect(
                recordID: "phone-a",
                trigger: .discovery(address: "192.0.2.10:37123", eventID: 7),
                now: now,
                notBefore: legacyDeadline
            )
        )
        XCTAssertFalse(
            coordinator.mayAttemptAutomaticReconnect(
                recordID: "phone-a",
                trigger: .discovery(address: "192.0.2.10:37123", eventID: 7),
                now: now,
                notBefore: legacyDeadline
            )
        )
    }

    func testManualDisconnectIsHardCoordinatorState() {
        let coordinator = ConnectionCoordinator()
        coordinator.automaticReconnectTask = Task { await Task.yield() }

        coordinator.enterManualDisconnect()

        XCTAssertEqual(coordinator.automaticReconnectState, .manuallyDisconnected)
        XCTAssertNil(coordinator.automaticReconnectTask)
        XCTAssertFalse(coordinator.mayAttemptAutomaticReconnect(recordID: "phone-a", trigger: .networkRestored(eventID: 1)))
        XCTAssertNil(coordinator.beginAutomaticReconnect(recordID: "phone-a"))

        coordinator.leaveManualDisconnect()
        XCTAssertEqual(coordinator.automaticReconnectState, .idle)
        XCTAssertNotNil(coordinator.beginAutomaticReconnect(recordID: "phone-a"))
    }
}
