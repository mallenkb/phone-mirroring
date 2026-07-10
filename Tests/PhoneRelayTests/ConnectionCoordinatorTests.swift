import XCTest
@testable import PhoneRelay

@MainActor
final class ConnectionCoordinatorTests: XCTestCase {
    func testCancelAllCancelsAndClearsEveryOwnedTask() {
        let coordinator = ConnectionCoordinator()
        let tasks = (0..<9).map { _ in Task<Void, Never> { await Task.yield() } }
        coordinator.deviceWatcherTask = tasks[0]
        coordinator.qrPairingTask = tasks[1]
        coordinator.usbConnectTask = tasks[2]
        coordinator.usbWiFiAddressPrefillTask = tasks[3]
        coordinator.usbWiFiHandoffTask = tasks[4]
        coordinator.usbWiFiTakeoverTask = tasks[5]
        coordinator.wirelessStartTask = tasks[6]
        coordinator.reconnectTask = tasks[7]
        coordinator.disconnectRecoveryTask = tasks[8]

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
}
