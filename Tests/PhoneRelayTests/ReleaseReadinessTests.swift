import XCTest
import CryptoKit
@testable import PhoneRelay

final class ReleaseReadinessTests: XCTestCase {
    func testTrackedReleaseArtifactsMatchManifest() throws {
        let root = Self.repoRoot()
        let manifest = try String(
            contentsOf: root.appendingPathComponent("scripts/release-artifacts.sha256"),
            encoding: .utf8
        )

        let entries = manifest.split(whereSeparator: \.isNewline)
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            let fields = entry.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            XCTAssertEqual(fields.count, 2, "Malformed release artifact manifest entry: \(entry)")
            let expectedHash = String(fields[0])
            let relativePath = fields[1].trimmingCharacters(in: .whitespaces)
            let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actualHash, expectedHash, relativePath)
        }
    }

    func testScriptPackagingUsesOnlyTrackedReleaseArtifacts() throws {
        for scriptName in ["scripts/build_and_run.sh", "scripts/package_app.sh"] {
            let script = try String(
                contentsOf: Self.repoRoot().appendingPathComponent(scriptName),
                encoding: .utf8
            )
            XCTAssertTrue(script.contains("scripts/verify_tracked_artifacts.sh"), scriptName)
            XCTAssertTrue(script.contains("VENDORED_ADB"), scriptName)
            XCTAssertTrue(script.contains("RESOURCE_SCRCPY_SERVER"), scriptName)
            XCTAssertFalse(script.contains("command -v adb"), scriptName)
            XCTAssertFalse(script.contains("TMP_HELPERS/adb"), scriptName)
        }
    }

    func testReleaseVerifierFailsClosedWhenRequiredArtifactsAreMissing() throws {
        let verifier = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("scripts/verify_release_artifact.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(verifier.contains(#"[[ ! -x "$ADB_HELPER" ]]"#))
        XCTAssertTrue(verifier.contains(#"[[ ! -f "$SCRCPY_SERVER" ]]"#))
        XCTAssertTrue(verifier.contains("lipo -verify_arch"))
        XCTAssertTrue(verifier.contains("/usr/bin/unzip -tqq"))
    }

    func testDependencyLocksMatchAcrossBuildEntrypoints() throws {
        let root = Self.repoRoot()
        let swiftPMLock = root.appendingPathComponent("Package.resolved")
        let xcodeLock = root.appendingPathComponent(
            "App/PhoneRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let swiftPMPins = try Self.normalizedPackagePins(at: swiftPMLock)
        let xcodePins = try Self.normalizedPackagePins(at: xcodeLock)
        XCTAssertEqual(swiftPMPins, xcodePins)
        XCTAssertFalse(swiftPMPins.isEmpty)
    }

    func testWorkflowsPinActionsAndXcodeVersion() throws {
        let workflowDirectory = Self.repoRoot().appendingPathComponent(".github/workflows")
        let workflowURLs = try FileManager.default.contentsOfDirectory(
            at: workflowDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
        XCTAssertFalse(workflowURLs.isEmpty)

        let pinnedAction = try NSRegularExpression(
            pattern: #"^uses:\s+[^@\s]+@[0-9a-f]{40}(?:\s+#.*)?$"#
        )
        for workflowURL in workflowURLs {
            let workflow = try String(contentsOf: workflowURL, encoding: .utf8)
            XCTAssertFalse(workflow.contains("latest-stable"), workflowURL.lastPathComponent)
            for rawLine in workflow.split(whereSeparator: \.isNewline) {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("- ") { line.removeFirst(2) }
                guard line.hasPrefix("uses:") else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                XCTAssertNotNil(
                    pinnedAction.firstMatch(in: line, range: range),
                    "Unpinned action in \(workflowURL.lastPathComponent): \(line)"
                )
            }
            if workflow.contains("maxim-lobanov/setup-xcode") {
                XCTAssertTrue(workflow.contains(#"xcode-version: "16.4""#), workflowURL.lastPathComponent)
            }
        }
    }

    func testProjectSourcesTreatWarningsAsErrors() throws {
        let package = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let xcodeProject = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("App/PhoneRelay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertEqual(package.components(separatedBy: #".unsafeFlags(["-warnings-as-errors"])"#).count - 1, 2)
        XCTAssertEqual(xcodeProject.components(separatedBy: "SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;").count - 1, 2)
    }

    func testXcodeAppSandboxAllowsADBKeysAndConnections() throws {
        let entitlements = try Self.propertyList(at: Self.repoRoot()
            .appendingPathComponent("App/PhoneRelay.entitlements"))

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.device.usb"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.server"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.downloads.read-write"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true)
        XCTAssertEqual(
            entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String],
            [".android/"]
        )
        XCTAssertEqual(entitlements["com.apple.developer.usernotifications.communication"] as? Bool, true)
    }

    func testXcodeReleaseUsesDeveloperIDEntitlements() throws {
        let project = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("App/PhoneRelay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS = ../scripts/PhoneRelay.release.entitlements;"))
        XCTAssertTrue(project.contains(#"if [ \"${CONFIGURATION:-}\" = \"Release\" ]; then"#))
        XCTAssertTrue(project.contains(#"codesign --force --options runtime --sign \"$EXPANDED_CODE_SIGN_IDENTITY\" \"$ADB\""#))
        XCTAssertTrue(project.contains(#"[ -n \"${EXPANDED_CODE_SIGN_IDENTITY:-}\" ]"#))
        XCTAssertTrue(project.contains(#"--entitlements \"$SRCROOT/HelperInherit.entitlements\""#))
    }

    func testScriptPackagedReleaseStaysUnsandboxed() throws {
        // The script/notarize pipeline must stay UNSANDBOXED: the App Sandbox
        // breaks the adb stack (Wi-Fi handoff / adb-over-Wi-Fi). The Xcode
        // build is sandboxed on purpose for MAS/TestFlight; the daily-driver
        // script build is not. See the app-sandbox-breaks-adb-stack note.
        let entitlements = try Self.propertyList(at: Self.repoRoot()
            .appendingPathComponent("scripts/PhoneRelay.release.entitlements"))

        XCTAssertNil(entitlements["com.apple.security.app-sandbox"],
                     "Release entitlements must not enable the App Sandbox (breaks Wi-Fi adb).")

        let packageScript = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("scripts/package_app.sh"),
            encoding: .utf8
        )
        let notarizeScript = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("scripts/notarize.sh"),
            encoding: .utf8
        )
        let releaseWorkflow = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        let sparkleWorkflow = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(".github/workflows/sparkle-from-release.yml"),
            encoding: .utf8
        )
        let verifier = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("scripts/verify_release_artifact.sh"),
            encoding: .utf8
        )

        // Main app is still signed with the release entitlements...
        XCTAssertTrue(packageScript.contains("--entitlements \"$APP_ENTITLEMENTS\""))
        XCTAssertTrue(notarizeScript.contains("--entitlements \"$ENTITLEMENTS\""))
        // ...but helpers are NOT signed with sandbox-inherit entitlements, which
        // would be killed at exec under a non-sandboxed parent.
        XCTAssertFalse(packageScript.contains("HELPER_ENTITLEMENTS"))
        XCTAssertFalse(notarizeScript.contains("HELPER_ENTITLEMENTS"))
        // The final artifact is verified at every release boundary, including the
        // DMG and Sparkle repackage paths that previously let a sandboxed app ship.
        XCTAssertTrue(packageScript.contains("scripts/verify_release_artifact.sh \"$APP\""))
        XCTAssertTrue(notarizeScript.contains("\"$ROOT_DIR/scripts/verify_release_artifact.sh\" \"$APP\""))
        XCTAssertTrue(releaseWorkflow.contains("scripts/verify_release_artifact.sh \"$APP_PATH\""))
        XCTAssertTrue(sparkleWorkflow.contains("scripts/verify_release_artifact.sh dist/PhoneRelay.app"))
        XCTAssertTrue(verifier.contains("embedded.provisionprofile"))
        XCTAssertTrue(verifier.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(verifier.contains("com.apple.security.inherit"))
        XCTAssertTrue(verifier.contains("NSLocalNetworkUsageDescription"))
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

        let project = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("App/PhoneRelay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("HelperInherit.entitlements"))
        XCTAssertTrue(project.contains(#"--entitlements \"$SRCROOT/HelperInherit.entitlements\""#))
        XCTAssertTrue(project.contains(#"if [ \"${CONFIGURATION:-}\" = \"Release\" ]; then"#))
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

    func testReleaseVersionMetadataStaysInSyncAcrossBuildEntrypoints() throws {
        let project = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("App/PhoneRelay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let marketingVersion = try XCTUnwrap(Self.firstMatch(
            pattern: #"MARKETING_VERSION = ([^;]+);"#,
            in: project
        ))
        let buildNumber = try XCTUnwrap(Self.firstMatch(
            pattern: #"CURRENT_PROJECT_VERSION = ([^;]+);"#,
            in: project
        ))

        let swiftPMInfo = try Self.propertyList(at: Self.repoRoot()
            .appendingPathComponent("Sources/PhoneRelay/Info.plist"))
        XCTAssertEqual(swiftPMInfo["CFBundleShortVersionString"] as? String, marketingVersion)
        XCTAssertEqual(swiftPMInfo["CFBundleVersion"] as? String, buildNumber)

        for scriptName in ["scripts/build_and_run.sh", "scripts/package_app.sh"] {
            let script = try String(
                contentsOf: Self.repoRoot().appendingPathComponent(scriptName),
                encoding: .utf8
            )
            XCTAssertEqual(
                Self.shellDefault(named: "APP_VERSION", in: script),
                marketingVersion,
                "\(scriptName) should default to the Xcode marketing version"
            )
            XCTAssertEqual(
                Self.shellDefault(named: "BUILD_NUMBER", in: script),
                buildNumber,
                "\(scriptName) should default to the Xcode build number"
            )
        }
    }

    func testReleaseVersionComparisonHandlesTagsAndPatchOrdering() {
        XCTAssertTrue(AppModel.isReleaseVersionNewer("v0.1.2", than: "0.1.1"))
        XCTAssertTrue(AppModel.isReleaseVersionNewer("v0.1.10", than: "0.1.9"))
        XCTAssertTrue(AppModel.isReleaseVersionNewer("1.0", than: "0.9.9"))

        XCTAssertFalse(AppModel.isReleaseVersionNewer("v0.1.1", than: "0.1.1"))
        XCTAssertFalse(AppModel.isReleaseVersionNewer("v0.1.1", than: "0.1.2"))
        XCTAssertFalse(AppModel.isReleaseVersionNewer("0.1", than: "0.1.0"))
    }

    func testSparkleMetadataIsDeclaredForSelfHostedUpdates() throws {
        let expectedFeed = "https://phonerelay.mallenkb.com/appcast.xml"
        let expectedKey = "BRG3UL9d/8qtx7RJdobbGi1q87hpbEflfn1izHj/qgc="

        for plistPath in ["Sources/PhoneRelay/Info.plist", "App/Info.plist"] {
            let plist = try Self.propertyList(at: Self.repoRoot().appendingPathComponent(plistPath))
            XCTAssertEqual(plist["SUFeedURL"] as? String, expectedFeed, plistPath)
            XCTAssertEqual(plist["SUPublicEDKey"] as? String, expectedKey, plistPath)
            XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true, plistPath)
            XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, true, plistPath)
            XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 86_400, plistPath)
        }

        for scriptName in ["scripts/build_and_run.sh", "scripts/package_app.sh"] {
            let script = try String(
                contentsOf: Self.repoRoot().appendingPathComponent(scriptName),
                encoding: .utf8
            )
            XCTAssertEqual(Self.shellDefault(named: "SPARKLE_FEED_URL", in: script), expectedFeed)
            XCTAssertEqual(Self.shellDefault(named: "SPARKLE_PUBLIC_ED_KEY", in: script), expectedKey)
            XCTAssertTrue(script.contains("<key>SUFeedURL</key>"), scriptName)
            XCTAssertTrue(script.contains("<key>SUPublicEDKey</key>"), scriptName)
        }
    }

    func testReleaseWorkflowPublishesSparkleUpdateAssets() throws {
        let releaseWorkflow = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        let pagesWorkflow = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(".github/workflows/pages.yml"),
            encoding: .utf8
        )
        let sparkleScript = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("scripts/make_sparkle_update.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(releaseWorkflow.contains("scripts/make_sparkle_update.sh dist/PhoneRelay.app"))
        XCTAssertTrue(releaseWorkflow.contains("SPARKLE_PRIVATE_KEY"))
        XCTAssertTrue(releaseWorkflow.contains("dist/sparkle/${{ steps.version.outputs.zip_name }}"))
        XCTAssertTrue(releaseWorkflow.contains("dist/sparkle/appcast.xml"))
        XCTAssertTrue(pagesWorkflow.contains("gh release download --repo \"$REPO\" --pattern appcast.xml --output docs/appcast.xml --clobber"))
        XCTAssertTrue(sparkleScript.contains("ditto -c -k --keepParent"))
        XCTAssertTrue(sparkleScript.contains("generate_appcast"))
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

    private static func normalizedPackagePins(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let pins = try XCTUnwrap(dictionary["pins"] as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: pins, options: [.sortedKeys])
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func shellDefault(named name: String, in script: String) -> String? {
        firstMatch(pattern: #"\#(name)="\$\{\#(name):-([^}]+)\}""#, in: script)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
