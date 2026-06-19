import XCTest
@testable import PhoneRelay

final class SettingsAboutTabTests: XCTestCase {
    func testKeyboardShortcutsCatalogDocumentsPhoneEditingAndNavigationKeys() {
        let shortcuts = KeyboardShortcutsCatalog.groups
            .flatMap(\.items)
            .reduce(into: [String: String]()) { result, item in
                result[item.keys] = item.action
            }

        XCTAssertEqual(shortcuts["⌘A"], "Select all")
        XCTAssertEqual(shortcuts["⌘C"], "Copy (syncs to Mac)")
        XCTAssertEqual(shortcuts["⌘V"], "Paste from Mac")
        XCTAssertEqual(shortcuts["Return / Enter"], "Submit or add a line, depending on the app")
        XCTAssertEqual(shortcuts["⌘Return"], "Send in apps that use Ctrl+Enter")
        XCTAssertEqual(shortcuts["Tab"], "Move focus on the phone")
        XCTAssertEqual(shortcuts["Delete"], "Delete backward")
        XCTAssertEqual(shortcuts["Forward Delete"], "Delete forward")
        XCTAssertEqual(shortcuts["Arrow keys"], "Move the cursor or selection")
        XCTAssertEqual(shortcuts["Esc"], "Back")
    }

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

    func testConnectionHealthLocalNetworkRecommendationHasSettingsAction() throws {
        let settingsSource = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/AppModel.swift"),
            encoding: .utf8
        )
        let appDelegateSource = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("snapshot.recommendedFix == AppModel.localNetworkRecommendedFix"))
        XCTAssertTrue(settingsSource.contains("Button(\"Open Local Network\")"))
        XCTAssertTrue(settingsSource.contains("model.openLocalNetworkSettings()"))
        XCTAssertTrue(settingsSource.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(settingsSource.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(modelSource.contains("Privacy_LocalNetwork"))
        XCTAssertTrue(modelSource.contains("isAwaitingLocalNetworkSettingsReturn = true"))
        XCTAssertTrue(modelSource.contains("refreshLocalNetworkPermissionAfterSettingsReturn()"))
        XCTAssertTrue(modelSource.contains("scanADBDevices()"))
        XCTAssertFalse(modelSource.contains("NSWorkspace.shared.open(localNetworkSettingsURL)\n                    completion(false)"))
        XCTAssertTrue(appDelegateSource.contains("applicationDidBecomeActive"))
        XCTAssertTrue(appDelegateSource.contains("model.refreshLocalNetworkPermissionAfterSettingsReturn()"))
    }

    func testSavedDeviceRowsOfferConnectAndForgetWhenInactive() throws {
        let source = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(source.range(of: "private struct PairedPhoneRow"))
        let rowBody = String(source[rowStart.lowerBound...])
        let inactiveStart = try XCTUnwrap(rowBody.range(of: "} else {"))
        let inactiveBody = String(rowBody[inactiveStart.lowerBound...])
        let forgetRange = try XCTUnwrap(inactiveBody.range(of: "MoreMenuRow(title: \"Forget\", isDestructive: true)"))
        let menuRange = try XCTUnwrap(inactiveBody.range(of: "moreActionsMenu"))

        XCTAssertLessThan(menuRange.lowerBound, forgetRange.lowerBound)
        XCTAssertTrue(rowBody.contains(".popover(isPresented: $showMoreMenu, arrowEdge: .bottom)"))
        XCTAssertTrue(rowBody.contains("private var moreActionsDropdown: some View"))
        XCTAssertTrue(rowBody.contains("title: transport.connectTitle,\n                    subtitle: transport.connectSubtitle"))
        XCTAssertTrue(source.contains("case .wifi: return \"No cable. Same Wi-Fi network.\""))
        XCTAssertTrue(source.contains("case .usb: return \"Fastest and most reliable.\""))
        XCTAssertTrue(rowBody.contains("ForEach(availableTransports)"))
        XCTAssertTrue(rowBody.contains("onConnect(transport)"))
        XCTAssertFalse(rowBody.contains("private var connectRouteControl: some View"))
        XCTAssertTrue(rowBody.contains("Button(\"Disconnect\", action: onDisconnect)"))
        XCTAssertTrue(rowBody.contains(".buttonStyle(SettingsRowActionButtonStyle())"))
        XCTAssertTrue(source.contains("private struct SettingsRowActionButtonStyle: ButtonStyle"))
        XCTAssertFalse(rowBody.contains("enum Kind"))
        XCTAssertTrue(source.contains("static let width: CGFloat = 96"))
        XCTAssertTrue(source.contains("static let height: CGFloat = 28"))
        XCTAssertTrue(source.contains(".frame(minWidth: Self.width)"))
        XCTAssertTrue(source.contains(".frame(height: Self.height)"))
        XCTAssertTrue(rowBody.contains("connectionDetailRow(\"USB\", usbAddress ?? \"N/A\")"))
        XCTAssertTrue(rowBody.contains("connectionDetailRow(\"Wi-Fi\", wifiAddress ?? \"N/A\")"))
        XCTAssertTrue(rowBody.contains("HStack(alignment: .center, spacing: 14) {\n            TemplateResourceIcon"))
        XCTAssertTrue(rowBody.contains("VStack(alignment: .leading, spacing: 8) {\n                Text(record.displayName)"))
        XCTAssertTrue(rowBody.contains("connectionDetails"))
        XCTAssertFalse(rowBody.contains(".padding(.leading, 42)"))
        XCTAssertTrue(rowBody.contains("private var connectionDetails: some View"))
        XCTAssertTrue(rowBody.contains("Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3)"))
        XCTAssertTrue(rowBody.contains(".gridColumnAlignment(.leading)"))
        XCTAssertTrue(rowBody.contains(".textSelection(.enabled)"))
        XCTAssertFalse(rowBody.contains("VStack(alignment: .leading, spacing: 4) {\n                    if let usbAddress"))
        XCTAssertFalse(rowBody.contains("labeledValue(\"USB\", usbAddress)"))
        XCTAssertFalse(rowBody.contains("HStack(alignment: .center, spacing: 18) {\n            VStack(alignment: .trailing, spacing: 2)"))
        XCTAssertFalse(source.contains(".frame(minWidth: 88, minHeight: 36)"))
        XCTAssertFalse(rowBody.contains("} else if isOnline {\n            Button(\"Connect\", action: onConnect)\n        } else {\n            Button(\"Forget\""))
    }

    func testSavedDeviceRowsUseADBPresenceForWiFiAvailability() throws {
        let source = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("Sources/PhoneRelay/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("AppModel.rememberedAuthorizedDevice("))
        XCTAssertTrue(source.contains("in: model.latestAuthorizedADBDevices"))
        XCTAssertTrue(source.contains("!device.isUSB"))
        XCTAssertTrue(source.contains("return device.serial"))
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
