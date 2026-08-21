import XCTest
@testable import PhoneRelay

@MainActor
final class ConnectionCoordinatorTests: XCTestCase {
    func testCancelAllCancelsAndClearsEveryOwnedTask() {
        let coordinator = ConnectionCoordinator()
        let tasks = (0..<11).map { _ in Task<Void, Never> { await Task.yield() } }
        coordinator.deviceWatcherTask = tasks[0]
        coordinator.qrPairingTask = tasks[1]
        coordinator.usbConnectTask = tasks[2]
        coordinator.usbWiFiAddressPrefillTask = tasks[3]
        coordinator.usbWiFiHandoffTask = tasks[4]
        coordinator.usbWiFiTakeoverTask = tasks[5]
        coordinator.discoveredWiFiConnectTask = tasks[6]
        coordinator.wirelessStartTask = tasks[7]
        coordinator.reconnectTask = tasks[8]
        coordinator.disconnectRecoveryTask = tasks[9]
        coordinator.automaticReconnectTask = tasks[10]

        coordinator.cancelAll()

        XCTAssertTrue(tasks.allSatisfy(\.isCancelled))
        XCTAssertNil(coordinator.deviceWatcherTask)
        XCTAssertNil(coordinator.qrPairingTask)
        XCTAssertNil(coordinator.usbConnectTask)
        XCTAssertNil(coordinator.usbWiFiAddressPrefillTask)
        XCTAssertNil(coordinator.usbWiFiHandoffTask)
        XCTAssertNil(coordinator.usbWiFiTakeoverTask)
        XCTAssertNil(coordinator.discoveredWiFiConnectTask)
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
        let discoveredWiFi = Task<Void, Never> { await Task.yield() }
        coordinator.deviceWatcherTask = watcher
        coordinator.qrPairingTask = pairing
        coordinator.usbConnectTask = usbConnect
        coordinator.usbWiFiHandoffTask = handoff
        coordinator.reconnectTask = reconnect
        coordinator.wirelessStartTask = wirelessStart
        coordinator.disconnectRecoveryTask = recovery
        coordinator.usbWiFiTakeoverTask = takeover
        coordinator.discoveredWiFiConnectTask = discoveredWiFi

        coordinator.cancelWirelessReconnectWork()

        XCTAssertFalse(watcher.isCancelled)
        XCTAssertFalse(pairing.isCancelled)
        XCTAssertFalse(usbConnect.isCancelled)
        XCTAssertFalse(handoff.isCancelled)
        XCTAssertTrue(reconnect.isCancelled)
        XCTAssertTrue(wirelessStart.isCancelled)
        XCTAssertTrue(recovery.isCancelled)
        XCTAssertTrue(takeover.isCancelled)
        XCTAssertTrue(discoveredWiFi.isCancelled)
        XCTAssertNotNil(coordinator.deviceWatcherTask)
        XCTAssertNotNil(coordinator.qrPairingTask)
        XCTAssertNotNil(coordinator.usbConnectTask)
        XCTAssertNotNil(coordinator.usbWiFiHandoffTask)
        XCTAssertNil(coordinator.reconnectTask)
        XCTAssertNil(coordinator.wirelessStartTask)
        XCTAssertNil(coordinator.disconnectRecoveryTask)
        XCTAssertNil(coordinator.usbWiFiTakeoverTask)
        XCTAssertNil(coordinator.discoveredWiFiConnectTask)
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

    func testHandoffGenerationPreventsStaleTaskFromClearingReplacement() {
        let coordinator = ConnectionCoordinator()
        let firstGeneration = coordinator.beginUSBWiFiHandoff()
        coordinator.usbWiFiHandoffTask = Task { await Task.yield() }
        let secondGeneration = coordinator.beginUSBWiFiHandoff()
        coordinator.usbWiFiHandoffTask = Task { await Task.yield() }

        XCTAssertNotEqual(firstGeneration, secondGeneration)
        coordinator.finishUSBWiFiHandoff(firstGeneration)
        XCTAssertNotNil(coordinator.usbWiFiHandoffTask)
        coordinator.finishUSBWiFiHandoff(secondGeneration)
        XCTAssertNil(coordinator.usbWiFiHandoffTask)
    }

    func testExplicitUSBBlocksPreparedTakeoverOnlyForChosenSerial() {
        XCTAssertTrue(
            ConnectionCoordinator.TransportIntent.automatic
                .permitsPreparedWiFiTakeover(for: "USB-A")
        )
        XCTAssertFalse(
            ConnectionCoordinator.TransportIntent.manualUSB(serial: "USB-A")
                .permitsPreparedWiFiTakeover(for: "USB-A")
        )
        XCTAssertTrue(
            ConnectionCoordinator.TransportIntent.manualUSB(serial: "USB-A")
                .permitsPreparedWiFiTakeover(for: "USB-B")
        )
        XCTAssertFalse(
            ConnectionCoordinator.TransportIntent.manualWiFi
                .permitsPreparedWiFiTakeover(for: "USB-A")
        )
    }

    // MARK: - Legacy tcpip circuit breaker

    /// The breaker bars `adb tcpip` for a while, not forever: a phone that
    /// failed once — typically adbd mid-restart right after a reboot — must be
    /// armable again without relaunching the app.
    func testLegacyHandoffBreakerExpiresInsteadOfLastingTheSession() {
        let coordinator = ConnectionCoordinator()
        let now = Date()
        coordinator.noteLegacyHandoffFailure(serial: "USB-1", now: now)

        XCTAssertTrue(coordinator.isLegacyHandoffCoolingDown(serial: "USB-1", now: now))
        XCTAssertTrue(
            coordinator.isLegacyHandoffCoolingDown(serial: "USB-1", now: now.addingTimeInterval(59))
        )
        XCTAssertFalse(
            coordinator.isLegacyHandoffCoolingDown(serial: "USB-1", now: now.addingTimeInterval(61))
        )
        XCTAssertFalse(coordinator.isLegacyHandoffCoolingDown(serial: "USB-2", now: now))
    }

    /// Repeat failures escalate steeply, so a phone that truly can't do wireless
    /// adb isn't restarted on a loop (the old "USB mirror dies every few
    /// seconds" pathology the session-long verdict was protecting against).
    func testLegacyHandoffBreakerEscalates() {
        XCTAssertEqual(ConnectionCoordinator.legacyHandoffRetryDelay(failureCount: 1), 60)
        XCTAssertEqual(ConnectionCoordinator.legacyHandoffRetryDelay(failureCount: 2), 300)
        XCTAssertEqual(ConnectionCoordinator.legacyHandoffRetryDelay(failureCount: 3), 1800)
        XCTAssertEqual(ConnectionCoordinator.legacyHandoffRetryDelay(failureCount: 9), 1800)

        let coordinator = ConnectionCoordinator()
        let now = Date()
        coordinator.noteLegacyHandoffFailure(serial: "USB-1", now: now)
        coordinator.noteLegacyHandoffFailure(serial: "USB-1", now: now)
        XCTAssertTrue(
            coordinator.isLegacyHandoffCoolingDown(serial: "USB-1", now: now.addingTimeInterval(120))
        )
    }

    /// A proven Wi-Fi route clears the verdict outright.
    func testClearLegacyHandoffFailureUnblocksImmediately() {
        let coordinator = ConnectionCoordinator()
        coordinator.noteLegacyHandoffFailure(serial: "USB-1")
        coordinator.clearLegacyHandoffFailure(serial: "USB-1")
        XCTAssertFalse(coordinator.isLegacyHandoffCoolingDown(serial: "USB-1"))
    }

    func testResetClearsConnectionRuntimeState() {
        let coordinator = ConnectionCoordinator()
        coordinator.isAutoReconnectSuppressedForManualDisconnect = true
        coordinator.manualDisconnectKnownSerials = ["USB-1"]
        coordinator.failedAutoConnectTargets = ["192.0.2.1:5555": Date()]
        coordinator.autoConnectTargetsInFlight = ["192.0.2.1:5555"]
        coordinator.wirelessPinnedUSBSerials = ["USB-1"]
        coordinator.transportIntent = .manualUSB(serial: "USB-1")
        coordinator.launchReconnectDeadline = Date()
        coordinator.noteLegacyHandoffFailure(serial: "USB-1")

        coordinator.reset()

        XCTAssertFalse(coordinator.isAutoReconnectSuppressedForManualDisconnect)
        XCTAssertNil(coordinator.manualDisconnectKnownSerials)
        XCTAssertTrue(coordinator.failedAutoConnectTargets.isEmpty)
        XCTAssertTrue(coordinator.autoConnectTargetsInFlight.isEmpty)
        XCTAssertTrue(coordinator.wirelessPinnedUSBSerials.isEmpty)
        XCTAssertEqual(coordinator.transportIntent, .automatic)
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

    func testForegroundAutomaticReconnectCanCapBackgroundBackoff() {
        let coordinator = ConnectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<4 {
            _ = coordinator.recordAutomaticReconnectFailure(
                recordID: "phone-a",
                failure: .temporarilyUnavailable,
                now: now,
                maximumDelay: 5
            )
        }

        XCTAssertEqual(
            coordinator.automaticRetryStates["phone-a"]?.nextRetryAt,
            now.addingTimeInterval(5)
        )
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

    func testAutomaticReconnectCountsAsDialingOnlyWhileAttempting() {
        let coordinator = ConnectionCoordinator()
        XCTAssertFalse(coordinator.isAutomaticReconnectDialing)

        _ = coordinator.beginAutomaticReconnect(recordID: "phone-a")
        XCTAssertTrue(coordinator.isAutomaticReconnectDialing)

        // Parked in backoff: the flight is alive but off the wire, so the
        // background saved-route status probe may dial.
        _ = coordinator.recordAutomaticReconnectFailure(
            recordID: "phone-a",
            failure: .temporarilyUnavailable
        )
        XCTAssertFalse(coordinator.isAutomaticReconnectDialing)
    }

    func testManualConnectionWorkInFlightExcludesAutomaticReconnect() {
        let coordinator = ConnectionCoordinator()
        XCTAssertFalse(coordinator.hasManualConnectionWorkInFlight)

        // The automatic reconnect task consults this property, so it must not
        // count itself as manual work.
        coordinator.automaticReconnectTask = Task { await Task.yield() }
        XCTAssertFalse(coordinator.hasManualConnectionWorkInFlight)

        coordinator.reconnectTask = Task { await Task.yield() }
        XCTAssertTrue(coordinator.hasManualConnectionWorkInFlight)

        coordinator.cancelAll()
        XCTAssertFalse(coordinator.hasManualConnectionWorkInFlight)
    }
}
