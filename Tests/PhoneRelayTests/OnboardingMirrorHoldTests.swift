import AppKit
import XCTest
@testable import PhoneRelay

/// Covers the first-run presentation gate: while onboarding is on screen no
/// mirror session may start (so the connection/mirror windows never appear
/// next to the onboarding card), and after completion auto-mirror waits out a
/// short hold so the revealed connection screen is actually seen.
final class OnboardingMirrorHoldTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    func testAutoMirrorIsHeldWhileOnboardingIsActive() {
        XCTAssertTrue(
            AppModel.shouldHoldAutoMirrorStart(onboardingActive: true, holdUntil: nil, now: now)
        )
    }

    func testOnboardingHoldWinsEvenWithExpiredSettleWindow() {
        XCTAssertTrue(
            AppModel.shouldHoldAutoMirrorStart(
                onboardingActive: true,
                holdUntil: now.addingTimeInterval(-10),
                now: now
            )
        )
    }

    func testAutoMirrorIsHeldDuringPostOnboardingSettleWindow() {
        XCTAssertTrue(
            AppModel.shouldHoldAutoMirrorStart(
                onboardingActive: false,
                holdUntil: now.addingTimeInterval(AppModel.postOnboardingMirrorHoldDuration),
                now: now
            )
        )
    }

    func testAutoMirrorResumesOnceSettleWindowExpires() {
        XCTAssertFalse(
            AppModel.shouldHoldAutoMirrorStart(
                onboardingActive: false,
                holdUntil: now.addingTimeInterval(-0.1),
                now: now
            )
        )
    }

    func testAutoMirrorRunsFreelyWithoutOnboardingOrSettleWindow() {
        XCTAssertFalse(
            AppModel.shouldHoldAutoMirrorStart(onboardingActive: false, holdUntil: nil, now: now)
        )
    }

    func testSettleWindowIsThreeSecondsMax() {
        XCTAssertLessThanOrEqual(AppModel.postOnboardingMirrorHoldDuration, 3)
    }

    @MainActor
    func testCompletionClearsOnboardingActiveAndArmsSettleWindow() {
        let defaults = UserDefaults.standard
        let seenKey = "hasSeenFirstTimeUserOnboarding"
        let explicitKey = "MirrorBehavior.explicitDeviceSetupRequired"
        let previousSeen = defaults.object(forKey: seenKey)
        let previousExplicit = defaults.object(forKey: explicitKey)
        defer {
            restore(defaults, key: seenKey, value: previousSeen)
            restore(defaults, key: explicitKey, value: previousExplicit)
        }

        let model = AppModel(startBackgroundServices: false)
        model.setFirstRunOnboardingActive(true)
        XCTAssertTrue(model.isFirstRunOnboardingActive)

        model.completeFirstTimeUserOnboarding()

        XCTAssertFalse(model.isFirstRunOnboardingActive)
        XCTAssertTrue(defaults.bool(forKey: seenKey))
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The in-process Restart Onboarding path relies on the model hiding the
    /// connection window itself the moment onboarding becomes active.
    @MainActor
    func testActivatingOnboardingHidesConnectionWindow() {
        _ = NSApplication.shared
        let model = AppModel(startBackgroundServices: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        model.registerConnectionWindow(window)
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible)

        model.setFirstRunOnboardingActive(true)

        XCTAssertFalse(window.isVisible)
    }

    /// A delayed SwiftUI/AppKit registration can happen after the onboarding
    /// flag is already active. The registration itself must enforce the same
    /// invariant, otherwise the connection screen can reappear next to the
    /// first-run card during fresh install or Restart Onboarding.
    @MainActor
    func testRegisteringConnectionWindowDuringOnboardingHidesItImmediately() {
        _ = NSApplication.shared
        let model = AppModel(startBackgroundServices: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        model.setFirstRunOnboardingActive(true)
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible)

        model.registerConnectionWindow(window)

        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testQRCodePairingDoesNotStartWhileOnboardingIsActive() {
        let model = AppModel(startBackgroundServices: false)

        model.setFirstRunOnboardingActive(true)
        model.ensureQRCodePairingSession()

        XCTAssertNil(model.qrPairingSession)
        XCTAssertFalse(model.isQRCodePairingWaiting)
    }

    @MainActor
    func testActivatingOnboardingClearsExistingQRCodePairingSession() {
        let model = AppModel(startBackgroundServices: false)
        model.ensureQRCodePairingSession()
        XCTAssertNotNil(model.qrPairingSession)

        model.setFirstRunOnboardingActive(true)

        XCTAssertNil(model.qrPairingSession)
        XCTAssertFalse(model.isQRCodePairingWaiting)
    }
}
