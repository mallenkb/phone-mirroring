import XCTest

final class AppModelArchitectureTests: XCTestCase {
    func testPrimaryAppModelRemainsAnObservableFacade() throws {
        let source = try SourceTestSupport.source("Sources/PhoneRelay/AppModel.swift")
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count

        XCTAssertLessThanOrEqual(
            lineCount,
            2_300,
            "Keep workflows in focused extensions and runtime state in coordinators."
        )
        XCTAssertTrue(source.contains("let connectionCoordinator = ConnectionCoordinator()"))
        XCTAssertTrue(source.contains("let mirrorLifecycle = MirrorLifecycleCoordinator()"))
        XCTAssertFalse(source.contains("private var reconnectTask:"))
        XCTAssertFalse(source.contains("private var mirrorLaunchTask:"))
        XCTAssertFalse(source.contains("private var failedAutoConnectTargets:"))
        XCTAssertFalse(source.contains("private var consecutiveQuickMirrorFailures"))
    }

    func testWorkflowFilesStaySeparatedByResponsibility() throws {
        let connection = try SourceTestSupport.source("Sources/PhoneRelay/AppModel+Connection.swift")
        let mirror = try SourceTestSupport.source("Sources/PhoneRelay/AppModel+MirrorLifecycle.swift")
        let connectionRuntime = try SourceTestSupport.source("Sources/PhoneRelay/Services/ConnectionCoordinator.swift")
        let mirrorRuntime = try SourceTestSupport.source("Sources/PhoneRelay/Mirror/MirrorLifecycleCoordinator.swift")

        XCTAssertTrue(connection.contains("func startDeviceWatcher()"))
        XCTAssertTrue(connection.contains("func connectViaUSB()"))
        XCTAssertFalse(connection.contains("func launchNativeMirror("))
        XCTAssertTrue(mirror.contains("func launchNativeMirror("))
        XCTAssertTrue(mirror.contains("func noteMirrorSessionEnded()"))
        XCTAssertFalse(mirror.contains("func startDeviceWatcher()"))
        XCTAssertTrue(connectionRuntime.contains("var manualDisconnectKnownSerials"))
        XCTAssertTrue(connectionRuntime.contains("var failedLegacyHandoffSerials"))
        XCTAssertTrue(mirrorRuntime.contains("var consecutiveQuickFailures"))
        XCTAssertTrue(mirrorRuntime.contains("var missingTransportPollMisses"))
    }
}
