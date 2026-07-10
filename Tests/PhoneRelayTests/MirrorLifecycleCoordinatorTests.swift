import XCTest
@testable import PhoneRelay

@MainActor
final class MirrorLifecycleCoordinatorTests: XCTestCase {
    func testCancellationClearsOwnedTaskHandles() {
        let coordinator = MirrorLifecycleCoordinator()
        let launch = Task<Void, Never> { await Task.yield() }
        let restart = Task<Void, Never> { await Task.yield() }
        coordinator.launchTask = launch
        coordinator.settingsRestartTask = restart

        coordinator.cancelLaunch()
        coordinator.cancelSettingsRestart()

        XCTAssertTrue(launch.isCancelled)
        XCTAssertTrue(restart.isCancelled)
        XCTAssertNil(coordinator.launchTask)
        XCTAssertNil(coordinator.settingsRestartTask)
        XCTAssertFalse(coordinator.isLaunching)
    }

    func testResetClearsBackoffAndAdvancesGeneration() {
        let coordinator = MirrorLifecycleCoordinator()
        coordinator.lastStartAt = Date()
        coordinator.consecutiveQuickFailures = 4
        coordinator.autoBackoffUntil = Date().addingTimeInterval(30)
        coordinator.missingTransportPollMisses = 2
        coordinator.startGeneration = 8
        coordinator.hasCompletedSuccessfulConnection = true

        coordinator.reset()

        XCTAssertNil(coordinator.lastStartAt)
        XCTAssertEqual(coordinator.consecutiveQuickFailures, 0)
        XCTAssertNil(coordinator.autoBackoffUntil)
        XCTAssertEqual(coordinator.missingTransportPollMisses, 0)
        XCTAssertEqual(coordinator.startGeneration, 9)
        XCTAssertFalse(coordinator.hasCompletedSuccessfulConnection)
    }
}
