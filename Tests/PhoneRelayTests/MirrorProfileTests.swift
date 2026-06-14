import XCTest
@testable import PhoneRelay

@MainActor
final class MirrorProfileTests: XCTestCase {
    private let profileKey = AppModel.mirrorProfileDefaultsKey
    private let maxSizeKey = "MirrorQuality.maxSize"
    private let bitRateKey = "MirrorQuality.bitRateMbps"
    private let maxFpsKey = "MirrorQuality.maxFps"
    private let audioKey = "MirrorQuality.experimentalOpusAudioEnabled"

    override func setUp() {
        super.setUp()
        clearMirrorQualityDefaults()
    }

    override func tearDown() {
        clearMirrorQualityDefaults()
        super.tearDown()
    }

    func testMirrorProfileDefaultsToRecording() {
        XCTAssertEqual(AppModel.defaultMirrorProfile(storedValue: nil), .recording)
        XCTAssertEqual(AppModel.defaultMirrorProfile(storedValue: "unknown"), .recording)
    }

    func testSelectingMirrorProfilePersistsAndAppliesQualitySettings() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.selectedMirrorProfile = .lowLatency

        XCTAssertEqual(UserDefaults.standard.string(forKey: profileKey), MirrorProfile.lowLatency.rawValue)
        XCTAssertEqual(model.mirrorMaxSize, 1280)
        XCTAssertEqual(model.mirrorBitRateMbps, 4)
        XCTAssertEqual(model.mirrorMaxFps, 60)
        XCTAssertTrue(model.mirrorAudioEnabled)
    }

    func testBatteryFriendlyProfileReducesFrameRateBitrateAndAudioLoad() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.applyMirrorProfile(.batteryFriendly)

        XCTAssertEqual(model.mirrorMaxSize, 1080)
        XCTAssertEqual(model.mirrorBitRateMbps, 2)
        XCTAssertEqual(model.mirrorMaxFps, 30)
        XCTAssertFalse(model.mirrorAudioEnabled)
    }

    func testSmoothProfileChoosesHighestFrameRatePreset() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.applyMirrorProfile(.smooth)

        XCTAssertEqual(model.mirrorMaxSize, 1600)
        XCTAssertEqual(model.mirrorBitRateMbps, 8)
        XCTAssertEqual(model.mirrorMaxFps, 120)
        XCTAssertTrue(model.mirrorAudioEnabled)
        XCTAssertEqual(MirrorProfile.smooth.detail, "1600p · 8 Mbps · 120 Hz")
    }

    func testSettingsViewExposesMirrorProfilesControl() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("Mirror profiles"))
        XCTAssertTrue(source.contains("mirrorProfileCard"))
        XCTAssertTrue(source.contains("ForEach(MirrorProfile.allCases)"))
        XCTAssertTrue(source.contains("profile.detail"))
        XCTAssertTrue(source.contains("checkmark.circle.fill"))
    }

    private func clearMirrorQualityDefaults() {
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: maxSizeKey)
        UserDefaults.standard.removeObject(forKey: bitRateKey)
        UserDefaults.standard.removeObject(forKey: maxFpsKey)
        UserDefaults.standard.removeObject(forKey: audioKey)
    }
}
