import XCTest
@testable import PhoneRelay

/// Covers the duplicate-instance guard (only one Phone Relay may run at a time;
/// a fresh launch yields to the already-running copy) and the connection-window presentation policy
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

    func testNewerLaunchFindsOlderInstanceToYieldTo() {
        let older = instance(pid: 100, launchedAt: 100)
        let newer = instance(pid: 200, launchedAt: 200)

        XCTAssertEqual(AppDelegate.olderDuplicateInstances(candidates: [older, newer], current: newer).map(\.pid), [100])
    }

    func testOlderLaunchDoesNotYieldToNewerInstance() {
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

    func testLaunchWindowIsExplicitlyBroughtToFront() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("private func bringLaunchWindowToFront(_ window: NSWindow)"))
        XCTAssertTrue(source.contains("model.beginForegroundLaunchPresentation()"))
        XCTAssertTrue(source.contains("installForegroundPresentationExitMonitor()"))
        XCTAssertTrue(source.contains("public func applicationDidResignActive"))
        XCTAssertTrue(source.contains("model.endForegroundLaunchPresentation()"))
        XCTAssertTrue(source.contains("guard model.shouldPreserveForegroundLaunchPresentationAfterResign else"))
        XCTAssertTrue(source.contains("NSApp.setActivationPolicy(.regular)"))
        XCTAssertTrue(source.contains("NSRunningApplication.current.unhide()"))
        XCTAssertTrue(source.contains("NSApp.unhide(nil)"))
        // Single-pass raise: the old floating-level juggle and full double
        // invoke were the visible launch "flash" (fixed 2026-07-05).
        XCTAssertFalse(source.contains("window.level = .floating"))
        XCTAssertTrue(source.contains("window.orderFrontRegardless()"))
        XCTAssertTrue(source.contains("window.makeKeyAndOrderFront(nil)"))
        XCTAssertTrue(source.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(source.contains("if window.isVisible, !window.isKeyWindow, NSApp.isActive {"))
        // Background (-g) launches must show without stealing focus.
        XCTAssertTrue(source.contains("} else if launchedInBackground {"))
        XCTAssertTrue(source.contains("window.orderFront(nil)"))
        XCTAssertTrue(source.contains("bringLaunchWindowToFront(window)"))
    }

    func testReopenUsesLaunchForegroundPath() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift", encoding: .utf8)
        let reopenRange = try XCTUnwrap(source.range(of: "public func applicationShouldHandleReopen"))
        let remainder = source[reopenRange.lowerBound...]
        let returnRange = try XCTUnwrap(remainder.range(of: "return false"))
        let reopenBody = remainder[..<returnRange.upperBound]

        XCTAssertTrue(reopenBody.contains("bringLaunchWindowToFront(target)"))
        XCTAssertTrue(reopenBody.contains("beginUserRequestedForegroundPresentation()"))
        XCTAssertFalse(reopenBody.contains("target.makeKeyAndOrderFront(nil)"))
        XCTAssertFalse(reopenBody.contains("NSApp.activate(ignoringOtherApps: true)"))
    }

    func testOutsideClickIsForegroundPresentationEscapeHatch() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("private var foregroundExitMonitor: Any?"))
        XCTAssertTrue(source.contains("private func installForegroundPresentationExitMonitor()"))
        XCTAssertTrue(source.contains("matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]"))
        XCTAssertTrue(source.contains("guard !self.pointerIsInsideVisibleAppWindow() else { return }"))
        XCTAssertTrue(source.contains("private func pointerIsInsideVisibleAppWindow() -> Bool"))
        XCTAssertTrue(source.contains("let point = NSEvent.mouseLocation"))
        XCTAssertTrue(source.contains("window.isVisible && window.frame.contains(point)"))
        XCTAssertTrue(source.contains("self.model.endForegroundLaunchPresentation()"))
        XCTAssertTrue(source.contains("NSEvent.removeMonitor(foregroundExitMonitor)"))
    }

    // MARK: - Connection window presentation

    func testConnectionWindowOnlyTakesFocusWhenAppIsActive() {
        XCTAssertEqual(AppModel.connectionWindowPresentation(appIsActive: true), .activateAndMakeKey)
        XCTAssertEqual(AppModel.connectionWindowPresentation(appIsActive: false), .orderFrontOnly)
    }

    func testForegroundLaunchKeepsConnectionAndMirrorPresentationAssertive() throws {
        let modelSource = try String(contentsOfFile: "Sources/PhoneRelay/AppModel.swift", encoding: .utf8)
        let mirrorWindowSource = try String(
            contentsOfFile: "Sources/PhoneRelay/Mirror/MirrorContentWindowController.swift",
            encoding: .utf8
        )

        XCTAssertTrue(modelSource.contains("private var foregroundLaunchPresentationActive = false"))
        XCTAssertTrue(modelSource.contains("var shouldPreserveForegroundLaunchPresentationAfterResign: Bool"))
        // The presentation defends the launch for a bounded window only —
        // unbounded, it re-raised on every resign ("flashing tug-of-war").
        XCTAssertTrue(modelSource.contains("foregroundLaunchPresentationWindow: TimeInterval = 3"))
        XCTAssertTrue(modelSource.contains("Date().timeIntervalSince(startedAt) < Self.foregroundLaunchPresentationWindow"))
        XCTAssertTrue(modelSource.contains("var shouldAssertForegroundPresentation: Bool"))
        XCTAssertTrue(modelSource.contains("foregroundLaunchPresentationActive || NSApp?.isActive == true"))
        XCTAssertTrue(modelSource.contains("let launchFrame = mirrorLaunchFrameForNextSession()"))
        XCTAssertTrue(modelSource.contains("private func mirrorLaunchFrameForNextSession() -> NSRect?"))
        XCTAssertTrue(modelSource.contains("return activeScreen.frame.intersects(candidate) ? candidate : nil"))
        XCTAssertTrue(modelSource.contains("?? (shouldAssertForegroundPresentation"))
        XCTAssertTrue(modelSource.contains("connectionWindowPresentation(appIsActive: shouldAssertForegroundPresentation)"))
        XCTAssertTrue(modelSource.contains("if shouldAssertForegroundPresentation {\n            NSApp?.activate(ignoringOtherApps: true)\n        }"))
        XCTAssertTrue(mirrorWindowSource.contains("if model.shouldAssertForegroundPresentation {\n            NSApp.activate(ignoringOtherApps: true)\n        }"))
    }
}
