import XCTest
@testable import PhoneRelay

@MainActor
final class MirrorScrollSpeedTests: XCTestCase {
    private let speedDefaultsKey = "MirrorBehavior.scrollSpeedPercent"
    private let feelDefaultsKey = "MirrorBehavior.scrollFeel"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: speedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: feelDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: speedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: feelDefaultsKey)
        super.tearDown()
    }

    func testMirrorScrollSpeedDefaultsToReadableNormalSpeed() {
        XCTAssertEqual(AppModel.defaultMirrorScrollSpeedPercent(storedValue: nil), 20)
    }

    func testMirrorScrollSpeedPreferencePersists() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.mirrorScrollSpeedPercent = 65

        XCTAssertEqual(UserDefaults.standard.integer(forKey: speedDefaultsKey), 65)
    }

    func testMirrorScrollFeelDefaultsToBalanced() {
        XCTAssertEqual(AppModel.defaultMirrorScrollFeel(storedValue: nil), .balanced)
        XCTAssertEqual(AppModel.defaultMirrorScrollFeel(storedValue: "unknown"), .balanced)
        XCTAssertEqual(AppModel.defaultMirrorScrollFeel(storedValue: "smooth"), .smooth)
    }

    func testMirrorScrollFeelPreferencePersists() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.mirrorScrollFeel = .smooth

        XCTAssertEqual(UserDefaults.standard.string(forKey: feelDefaultsKey), "smooth")
    }

    func testMirrorScrollDeltasAreScaledBySelectedSpeed() {
        XCTAssertEqual(AppModel.scaledMirrorScrollDelta(80, speedPercent: 20), 16)
        XCTAssertEqual(AppModel.scaledMirrorScrollDelta(-40, speedPercent: 35), -14)
    }

    func testMirrorScrollFeelShapesScaledDeltas() {
        XCTAssertEqual(
            AppModel.shapedMirrorScrollDelta(80, speedPercent: 20, feel: .direct),
            16,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            abs(AppModel.shapedMirrorScrollDelta(80, speedPercent: 20, feel: .balanced)),
            16
        )
        XCTAssertLessThan(
            abs(AppModel.shapedMirrorScrollDelta(80, speedPercent: 20, feel: .smooth)),
            abs(AppModel.shapedMirrorScrollDelta(80, speedPercent: 20, feel: .balanced))
        )
        XCTAssertLessThan(
            AppModel.shapedMirrorScrollDelta(-80, speedPercent: 20, feel: .smooth),
            0
        )
    }

    func testHorizontalDominantTrackpadScrollUsesTouchSwipe() {
        XCTAssertTrue(MirrorSession.shouldUseHorizontalTrackpadSwipe(deltaX: 18, deltaY: 2))
        XCTAssertTrue(MirrorSession.shouldUseHorizontalTrackpadSwipe(deltaX: -18, deltaY: 2))
        XCTAssertFalse(MirrorSession.shouldUseHorizontalTrackpadSwipe(deltaX: 4, deltaY: 0))
        XCTAssertFalse(MirrorSession.shouldUseHorizontalTrackpadSwipe(deltaX: 10, deltaY: 9))
        XCTAssertFalse(MirrorSession.shouldUseHorizontalTrackpadSwipe(deltaX: 2, deltaY: 18))
    }

    func testHorizontalTrackpadSwipeTargetMovesAcrossThePhoneSurface() {
        let leftSwipe = ScrcpyControlChannel.horizontalTrackpadSwipeEndPoint(
            from: CGPoint(x: 0.5, y: 0.4),
            deltaX: 44
        )
        let rightSwipe = ScrcpyControlChannel.horizontalTrackpadSwipeEndPoint(
            from: CGPoint(x: 0.5, y: 0.4),
            deltaX: -44
        )

        XCTAssertLessThan(leftSwipe.x, 0.5)
        XCTAssertGreaterThan(rightSwipe.x, 0.5)
        XCTAssertEqual(leftSwipe.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(rightSwipe.y, 0.4, accuracy: 0.001)
        XCTAssertLessThan(abs(leftSwipe.x - 0.5), 0.12)
    }

    func testShiftScrollMapsVerticalWheelToHorizontalMovement() {
        let shifted = MirrorRenderView.deviceScrollDeltas(
            deltaX: 0,
            deltaY: 24,
            modifierFlags: [.shift]
        )
        let normal = MirrorRenderView.deviceScrollDeltas(
            deltaX: 0,
            deltaY: 24,
            modifierFlags: []
        )
        let horizontalMouse = MirrorRenderView.deviceScrollDeltas(
            deltaX: -18,
            deltaY: 2,
            modifierFlags: []
        )

        XCTAssertEqual(shifted.x, 24)
        XCTAssertEqual(shifted.y, 0)
        XCTAssertEqual(normal.x, 0)
        XCTAssertEqual(normal.y, 24)
        XCTAssertEqual(horizontalMouse.x, -18)
        XCTAssertEqual(horizontalMouse.y, 2)
    }

    func testSettingsViewExposesMirrorScrollSpeedControl() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("Scroll speed"))
        XCTAssertTrue(source.contains("Scroll feel"))
        XCTAssertTrue(source.contains("$model.mirrorScrollSpeedPercent"))
        XCTAssertTrue(source.contains("$model.mirrorScrollFeel"))
        XCTAssertTrue(source.contains("icon: \"scroll\""))
        XCTAssertTrue(source.contains("icon: \"waveform.path\""))
        XCTAssertTrue(source.contains("scrollingPickerRow"))
        XCTAssertTrue(source.contains("MirrorScrollFeel.allCases"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(source.contains(".fixedSize()"))
    }
}
