import XCTest
@testable import PhoneRelay

final class GitHubReleaseUpdaterTests: XCTestCase {
    func testVersionComparisonIgnoresLeadingVAndMissingPatchParts() {
        XCTAssertEqual(GitHubReleaseUpdater.compareVersions("v0.1.2", "0.1.1"), 1)
        XCTAssertEqual(GitHubReleaseUpdater.compareVersions("0.1", "0.1.0"), 0)
        XCTAssertEqual(GitHubReleaseUpdater.compareVersions("0.1.1", "0.1.2"), -1)
    }

    func testPreferredInstallerAssetUsesPhoneRelayDMGBeforeOtherDMGs() {
        let release = GitHubRelease(
            assets: [
                .init(browserDownloadURL: URL(string: "https://example.com/other.dmg")!, name: "Other.dmg", size: nil),
                .init(browserDownloadURL: URL(string: "https://example.com/PhoneRelay.dmg")!, name: "PhoneRelay.dmg", size: nil)
            ],
            htmlURL: nil,
            name: "PhoneRelay 0.1.2",
            tagName: "v0.1.2"
        )

        XCTAssertEqual(
            GitHubReleaseUpdater.preferredInstallerAsset(in: release)?.name,
            "PhoneRelay.dmg"
        )
    }

    func testPreferredInstallerAssetFallsBackToAnyDMG() {
        let release = GitHubRelease(
            assets: [
                .init(browserDownloadURL: URL(string: "https://example.com/readme.txt")!, name: "readme.txt", size: nil),
                .init(browserDownloadURL: URL(string: "https://example.com/PhoneRelay-0.1.2.dmg")!, name: "PhoneRelay-0.1.2.dmg", size: nil)
            ],
            htmlURL: nil,
            name: "PhoneRelay 0.1.2",
            tagName: "v0.1.2"
        )

        XCTAssertEqual(
            GitHubReleaseUpdater.preferredInstallerAsset(in: release)?.name,
            "PhoneRelay-0.1.2.dmg"
        )
    }
}
