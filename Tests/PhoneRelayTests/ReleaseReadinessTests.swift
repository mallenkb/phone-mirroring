import XCTest
@testable import PhoneRelay

final class ReleaseReadinessTests: XCTestCase {
    func testAppStoreEntitlementsAllowDownloadsForCaptures() throws {
        let entitlements = try Self.propertyList(at: Self.repoRoot()
            .appendingPathComponent("App/PhoneRelay.entitlements"))

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.downloads.read-write"] as? Bool, true)
    }

    func testBundledADBHelperUsesSandboxInheritanceEntitlements() throws {
        let entitlements = try Self.propertyList(at: Self.repoRoot()
            .appendingPathComponent("App/HelperInherit.entitlements"))

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.inherit"] as? Bool, true)
        XCTAssertEqual(Set(entitlements.keys), [
            "com.apple.security.app-sandbox",
            "com.apple.security.inherit"
        ])
    }

    @MainActor
    func testScreenshotCaptureSavesIntoDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf 'PNGDATA'
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.selectedDevice = MirrorDevice(
            id: "adb-test",
            name: "Test Phone",
            model: "Test Phone",
            battery: 80,
            isCharging: false,
            network: "USB debugging",
            lastSeen: .now,
            states: [.mirroringReady],
            adbSerial: "TESTSERIAL"
        )

        model.takeScreenshot()

        let captureURL = try await Self.waitForCaptureURL(in: model)
        defer { try? FileManager.default.removeItem(at: captureURL) }

        XCTAssertEqual(captureURL.deletingLastPathComponent().lastPathComponent, "Downloads")
        XCTAssertTrue(captureURL.lastPathComponent.hasPrefix("Android-Mirroring-Screenshot_"))
    }

    func testReviewURLsAreDeclaredForInAppAccess() throws {
        XCTAssertEqual(AppModel.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(AppModel.supportURL.scheme, "https")
        XCTAssertEqual(AppModel.releaseMetadataURL.scheme, "https")
        XCTAssertEqual(AppModel.latestReleaseURL.scheme, "https")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoRoot()
            .appendingPathComponent("docs/privacy.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoRoot()
            .appendingPathComponent("docs/support.html").path))
    }

    func testXcodeProjectGeneratesDSYMsForDebuggableAppBuilds() throws {
        let project = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("App/PhoneRelay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";"))
        XCTAssertFalse(project.contains("DEBUG_INFORMATION_FORMAT = dwarf;"))
        XCTAssertTrue(project.contains("GCC_GENERATE_DEBUGGING_SYMBOLS = YES;"))
        XCTAssertTrue(project.contains("STRIP_INSTALLED_PRODUCT = NO;"))
    }

    func testReleaseVersionComparisonHandlesTagsAndPatchOrdering() {
        XCTAssertTrue(AppModel.isReleaseVersionNewer("v0.1.2", than: "0.1.1"))
        XCTAssertTrue(AppModel.isReleaseVersionNewer("v0.1.10", than: "0.1.9"))
        XCTAssertTrue(AppModel.isReleaseVersionNewer("1.0", than: "0.9.9"))

        XCTAssertFalse(AppModel.isReleaseVersionNewer("v0.1.1", than: "0.1.1"))
        XCTAssertFalse(AppModel.isReleaseVersionNewer("v0.1.1", than: "0.1.2"))
        XCTAssertFalse(AppModel.isReleaseVersionNewer("0.1", than: "0.1.0"))
    }

    private static func waitForCaptureURL(in model: AppModel) async throws -> URL {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let url = await MainActor.run(body: { model.lastCaptureURL }) {
                return url
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "ReleaseReadinessTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for screenshot capture"]
        )
    }

    private static func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
