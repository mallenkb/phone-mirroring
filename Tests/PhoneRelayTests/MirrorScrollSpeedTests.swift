import XCTest
@testable import PhoneRelay

@MainActor
final class MirrorScrollSpeedTests: XCTestCase {
    private let defaultsKey = "MirrorBehavior.scrollSpeedPercent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testMirrorScrollSpeedDefaultsToReadableNormalSpeed() {
        XCTAssertEqual(AppModel.defaultMirrorScrollSpeedPercent(storedValue: nil), 20)
    }

    func testMirrorScrollSpeedPreferencePersists() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.mirrorScrollSpeedPercent = 65

        XCTAssertEqual(UserDefaults.standard.integer(forKey: defaultsKey), 65)
    }

    func testMirrorScrollDeltasAreScaledBySelectedSpeed() {
        XCTAssertEqual(AppModel.scaledMirrorScrollDelta(80, speedPercent: 20), 16)
        XCTAssertEqual(AppModel.scaledMirrorScrollDelta(-40, speedPercent: 35), -14)
    }

    func testSettingsViewExposesMirrorScrollSpeedControl() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("Mirror scroll speed"))
        XCTAssertTrue(source.contains("$model.mirrorScrollSpeedPercent"))
        XCTAssertTrue(source.contains("settingsScrollSpeedRow"))
        XCTAssertTrue(source.contains("settingsLeadingIcon(\"scroll\", isActive: true)"))
    }
}
