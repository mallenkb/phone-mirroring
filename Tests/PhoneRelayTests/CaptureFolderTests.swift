import XCTest
@testable import PhoneRelay

@MainActor
final class CaptureFolderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearCaptureDefaults()
    }

    override func tearDown() {
        clearCaptureDefaults()
        unsetenv("ANDROID_MIRROR_ADB_PATH")
        super.tearDown()
    }

    func testCaptureFolderPreferencesPersistSeparateScreenshotAndRecordingPaths() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayCaptureFolders-\(UUID().uuidString)", isDirectory: true)
        let screenshotFolder = base.appendingPathComponent("Screenshots", isDirectory: true)
        let recordingFolder = base.appendingPathComponent("Recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.setScreenshotFolder(screenshotFolder)
        model.setRecordingFolder(recordingFolder)

        XCTAssertEqual(model.screenshotFolderPath, screenshotFolder.path)
        XCTAssertEqual(model.recordingFolderPath, recordingFolder.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppModel.screenshotFolderPathDefaultsKey), screenshotFolder.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppModel.recordingFolderPathDefaultsKey), recordingFolder.path)
    }

    func testResetCaptureFolderFallsBackToDefaultDownloadsPath() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayScreenshots-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.setScreenshotFolder(folder)
        model.resetScreenshotFolder()

        XCTAssertNil(model.screenshotFolderPath)
        XCTAssertNil(model.screenshotOutputDirectory())
        XCTAssertNil(UserDefaults.standard.string(forKey: AppModel.screenshotFolderPathDefaultsKey))
    }

    func testScreenshotCaptureUsesSelectedFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayScreenshotCapture-\(UUID().uuidString)", isDirectory: true)
        let destination = base.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fakeADB = base.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf 'PNGDATA'
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeADB.path)
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let result = await Task.detached {
            MediaCaptureService.captureScreenshot(serial: "TESTSERIAL", outputDirectory: destination)
        }.value

        let captureURL = try result.get()
        XCTAssertEqual(captureURL.deletingLastPathComponent(), destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testSettingsViewExposesSeparateCaptureFolderControls() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("Saved files"))
        XCTAssertTrue(source.contains("model.screenshotFolderPath"))
        XCTAssertTrue(source.contains("model.recordingFolderPath"))
        XCTAssertTrue(source.contains("model.chooseScreenshotFolder"))
        XCTAssertTrue(source.contains("model.chooseRecordingFolder"))
    }

    func testRecordingMaxMinutesClampsToSupportedRange() {
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(0), AppModel.recordingMaxMinutesRange.lowerBound)
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(-5), AppModel.recordingMaxMinutesRange.lowerBound)
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(10), 10)
        XCTAssertEqual(AppModel.clampedRecordingMaxMinutes(9999), AppModel.recordingMaxMinutesRange.upperBound)
    }

    func testRecordingMaxMinutesPersistsAndDerivesTimeLimitSeconds() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        XCTAssertEqual(model.recordingMaxMinutes, AppModel.recordingMaxMinutesDefault)
        XCTAssertEqual(model.recordingTimeLimitSeconds, AppModel.recordingMaxMinutesDefault * 60)

        model.recordingMaxMinutes = 10
        XCTAssertEqual(model.recordingMaxMinutes, 10)
        XCTAssertEqual(model.recordingTimeLimitSeconds, 600)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AppModel.recordingMaxMinutesDefaultsKey), 10)

        // Out-of-range assignments are clamped, not stored verbatim.
        model.recordingMaxMinutes = 100_000
        XCTAssertEqual(model.recordingMaxMinutes, AppModel.recordingMaxMinutesRange.upperBound)
    }

    func testRecordingLengthLabelFormatsMinutesAndHours() {
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 3), "3 min")
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 30), "30 min")
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 60), "1 hour")
        XCTAssertEqual(SettingsView.recordingLengthLabel(minutes: 120), "2 hours")
    }

    func testScreenRecordingCommandPassesConfigurableTimeLimit() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppModel.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("screenrecord --time-limit \\(timeLimitSeconds)"))
        let settings = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)
        XCTAssertTrue(settings.contains("$model.recordingMaxMinutes"))
    }

    private func clearCaptureDefaults() {
        UserDefaults.standard.removeObject(forKey: AppModel.screenshotFolderPathDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.screenshotFolderBookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.recordingFolderPathDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.recordingFolderBookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.recordingMaxMinutesDefaultsKey)
    }
}
