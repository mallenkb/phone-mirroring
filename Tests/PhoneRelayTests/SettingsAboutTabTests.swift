import XCTest
@testable import PhoneRelay

final class SettingsAboutTabTests: XCTestCase {
    func testSettingsViewDeclaresAboutTabWithReviewAndLegalLinks() throws {
        let source = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case about = \"About\""))
        XCTAssertTrue(source.contains("AboutContent.privacyPolicy"))
        XCTAssertTrue(source.contains("AboutContent.supportDetails"))
        XCTAssertTrue(source.contains("AboutContent.projectLicense"))
        XCTAssertTrue(source.contains("AboutContent.thirdPartyNotices"))
        XCTAssertTrue(source.contains("Privacy Policy"))
        XCTAssertTrue(source.contains("Support"))
        XCTAssertTrue(source.contains("Third-Party Notices"))
        XCTAssertTrue(source.contains("Open Source License"))
        XCTAssertTrue(source.contains("Version"))
        XCTAssertTrue(source.contains("Build"))
    }

    func testAboutDocumentsProvideLocalPolicyAndLicenseDetails() throws {
        let content = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Support/AboutContent.swift"),
            encoding: .utf8
        )
        let privacy = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Resources/About/PRIVACY_POLICY.txt"),
            encoding: .utf8
        )
        let license = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Resources/About/PHONERELAY_LICENSE.txt"),
            encoding: .utf8
        )
        let support = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Resources/About/SUPPORT.txt"),
            encoding: .utf8
        )
        let notices = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Resources/About/THIRD_PARTY_NOTICES.txt"),
            encoding: .utf8
        )
        let apacheLicense = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Resources/About/LICENSES/scrcpy-APACHE-2.0.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(license.contains("PhoneRelay App License"))
        XCTAssertTrue(license.contains("All rights reserved"))
        XCTAssertTrue(privacy.contains("does not run an analytics service"))
        XCTAssertTrue(support.contains("PhoneRelay version and build from the About tab"))
        XCTAssertTrue(notices.contains("scrcpy"))
        XCTAssertTrue(notices.contains("Apache License 2.0"))
        XCTAssertTrue(apacheLicense.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        XCTAssertFalse(apacheLicense.contains("For complete legal terms, see:"))
        XCTAssertTrue(content.contains("PhoneRelay App License"))
        XCTAssertTrue(content.contains("does not run an analytics service"))
    }

    func testAboutDocumentsAreBundledAsPlainTextResources() throws {
        let aboutDirectory = Self.repoRoot()
            .appendingPathComponent("Sources/PhoneRelay/Resources/About")
        let requiredTextResources = [
            "PRIVACY_POLICY.txt",
            "SUPPORT.txt",
            "PHONERELAY_LICENSE.txt",
            "THIRD_PARTY_NOTICES.txt",
            "LICENSES/scrcpy-APACHE-2.0.txt",
        ]
        let markdownResources = [
            "PRIVACY_POLICY.md",
            "SUPPORT.md",
            "PHONERELAY_LICENSE.md",
            "THIRD_PARTY_NOTICES.md",
            "LICENSES/scrcpy-APACHE-2.0.md",
        ]

        for resource in requiredTextResources {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: aboutDirectory.appendingPathComponent(resource).path),
                "Expected bundled About text resource: \(resource)"
            )
        }

        for resource in markdownResources {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: aboutDirectory.appendingPathComponent(resource).path),
                "About resources should be plain .txt files, not markdown: \(resource)"
            )
        }
    }

    func testXcodeWrapperCopiesLegalResourcesForAboutTab() throws {
        let project = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("App/PhoneRelay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("Copy legal resources"))
        XCTAssertTrue(project.contains("THIRD_PARTY_NOTICES.md"))
        XCTAssertTrue(project.contains("LICENSES/scrcpy-APACHE-2.0.txt"))
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
