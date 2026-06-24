import XCTest

final class AppMenuStateTests: XCTestCase {
    func testEditMenuKeepsStandardTextEditingShortcuts() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x""#))
        XCTAssertTrue(source.contains(#"title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c""#))
        XCTAssertTrue(source.contains(#"title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v""#))
        XCTAssertTrue(source.contains(#"title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a""#))
    }

    func testSettingsDisconnectRoutesToMainConnectionScreen() throws {
        let settingsSource = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift",
            encoding: .utf8
        )
        let appModelSource = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )
        let connectionSource = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/FigmaMirrorExperienceView.swift",
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("onDisconnect: { model.disconnectFromSettings() }"))
        XCTAssertTrue(appModelSource.contains("func disconnectFromSettings()"))
        XCTAssertTrue(appModelSource.contains("connectionWindowPrefersWirelessDetails = false"))
        XCTAssertTrue(appModelSource.contains("connectionWindowNavigationResetID += 1"))
        XCTAssertTrue(appModelSource.contains("showConnectionWindow(startsQRCodePairing: false)"))
        XCTAssertTrue(appModelSource.contains("refreshDevicePresenceAfterManualDisconnect()"))
        XCTAssertTrue(connectionSource.contains("syncPreferredConnectionStep()"))
        XCTAssertTrue(connectionSource.contains(".onChange(of: model.connectionWindowNavigationResetID)"))
        XCTAssertTrue(connectionSource.contains("connectionStep = .wirelessPairing"))
        XCTAssertTrue(connectionSource.contains("connectionStep = .chooseMethod"))
        XCTAssertTrue(connectionSource.contains("model.stopQRCodePairingSession()"))
    }

    func testSettingsDeviceRowsExposeTransportDropdownAndSingleConnectAction() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onConnect: { transport in model.connect(record: record, transport: transport.modelTransport) }"))
        XCTAssertTrue(source.contains(".popover(isPresented: $showMoreMenu, arrowEdge: .bottom)"))
        XCTAssertTrue(source.contains("private var moreActionsDropdown: some View"))
        XCTAssertTrue(source.contains("ForEach(availableTransports)"))
        XCTAssertTrue(source.contains("private var moreActionsMenu: some View"))
        XCTAssertTrue(source.contains("Image(systemName: \"ellipsis\")"))
        XCTAssertTrue(source.contains(".frame(width: 32, height: 32)"))
        XCTAssertTrue(source.contains("connectionDetailRow(\"USB\","))
        XCTAssertTrue(source.contains("connectionDetailRow(\"Wi-Fi\","))
        XCTAssertTrue(source.contains("activeADBSerial: model.selectedDevice.adbSerial"))
        XCTAssertTrue(source.contains("return \"Connected via \\(activeTransport.title)\""))
        XCTAssertTrue(source.contains("private var activeTransport: SettingsDeviceTransport?"))
    }

    func testSettingsActiveDeviceRowsShowOnlyDisconnect() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift",
            encoding: .utf8
        )
        let actionStart = try XCTUnwrap(source.range(of: "private var actionButtons: some View"))
        let actionEnd = try XCTUnwrap(source.range(of: "private var moreActionsMenu: some View"))
        let actionBody = String(source[actionStart.lowerBound..<actionEnd.lowerBound])

        XCTAssertTrue(actionBody.contains("if isActive {"))
        XCTAssertTrue(actionBody.contains("Button(\"Disconnect\", action: onDisconnect)"))
        XCTAssertTrue(actionBody.contains(".buttonStyle(SettingsRowActionButtonStyle())"))
        let elseRange = try XCTUnwrap(actionBody.range(of: "} else {"))
        let activeBody = String(actionBody[..<elseRange.lowerBound])
        XCTAssertFalse(activeBody.contains("moreActionsMenu"))
        XCTAssertFalse(source.contains(".frame(width: isActive ? SettingsRowActionButtonStyle.width : nil"))
    }

    func testSettingsDisconnectedRowsUseOnlyMoreMenuForActions() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift",
            encoding: .utf8
        )
        let actionStart = try XCTUnwrap(source.range(of: "private var actionButtons: some View"))
        let actionEnd = try XCTUnwrap(source.range(of: "private var rightColumn: some View"))
        let actionBody = String(source[actionStart.lowerBound..<actionEnd.lowerBound])

        XCTAssertTrue(actionBody.contains("} else {\n            moreActionsMenu"))
        XCTAssertTrue(actionBody.contains("moreActionsMenu"))
        XCTAssertFalse(actionBody.contains("connectRouteControl"))
        XCTAssertTrue(actionBody.contains("ForEach(availableTransports)"))
        XCTAssertTrue(actionBody.contains("onConnect(transport)"))
        XCTAssertTrue(actionBody.contains("MoreMenuRow(title: \"Forget\", isDestructive: true)"))
    }

    func testViewMenuModeItemsExposeOnAndOffStates() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Stop Presentation Mode"))
        XCTAssertTrue(source.contains("Start Presentation Mode"))
        XCTAssertTrue(source.contains("Stop Screen Recording"))
        XCTAssertTrue(source.contains("Start Screen Recording"))
        XCTAssertTrue(source.contains("model.isRecording ? .on : .off"))
        XCTAssertTrue(source.contains("screenRecordingMenuItem"))
        XCTAssertTrue(source.contains("model.$isRecording"))
        XCTAssertTrue(source.contains("updateScreenRecordingMenuItem()"))
        XCTAssertTrue(source.contains("return model.hasActiveMirrorSession || model.isRecording"))
        XCTAssertTrue(source.contains("return model.hasActiveMirrorSession || model.presentationModeEnabled"))
        XCTAssertTrue(source.contains("Turn Off Always on Top"))
        XCTAssertTrue(source.contains("Turn On Always on Top"))
        XCTAssertTrue(source.contains("return true"))
    }

    func testClosingLastWindowDoesNotTerminateDuringHandoff() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift",
            encoding: .utf8
        )
        let body = try sourceSlice(
            in: source,
            from: "public func applicationShouldTerminateAfterLastWindowClosed",
            to: "public func applicationDidBecomeActive"
        )

        XCTAssertTrue(body.contains("!model.isPerformingMirrorHandoffOrRecovery"))
    }

    func testTerminationClosesAllAppWindowsAfterModelShutdown() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppDelegate.swift",
            encoding: .utf8
        )
        let terminateBody = try sourceSlice(
            in: source,
            from: "public func applicationWillTerminate",
            to: "private func installMainMenu()"
        )

        XCTAssertTrue(terminateBody.contains("model.shutdown()"))
        XCTAssertTrue(terminateBody.contains("closeAllAppWindows()"))
        XCTAssertTrue(terminateBody.contains("window.childWindows?.forEach"))
        XCTAssertTrue(terminateBody.contains("window.close()"))
    }

    func testMirrorWindowCloseButtonTerminatesInsteadOfOrphaningSession() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/Mirror/MirrorContentWindowController.swift",
            encoding: .utf8
        )
        let closeBody = try sourceSlice(
            in: source,
            from: "func windowShouldClose",
            to: "func windowWillClose"
        )

        XCTAssertTrue(closeBody.contains("NSApplication.shared.terminate(nil)"))
        XCTAssertTrue(closeBody.contains("return false"))
    }

    func testPresentationModeStopClearsAndroidTouchIndicators() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("\"show_touches\", \"0\""))
        XCTAssertTrue(source.contains("\"pointer_location\", \"0\""))
        XCTAssertTrue(source.contains("Presentation mode disabled touch indicators"))
    }

    func testStoppingMirrorRestoresPresentationMode() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )

        let stopBody = try sourceSlice(
            in: source,
            from: "func stopMirroring(suspendAutoConnect: Bool = true)",
            to: "private func recoverMissingMirrorTransport()"
        )
        let sessionEndedBody = try sourceSlice(
            in: source,
            from: "session.onSessionEnded = { [weak self, weak session] finalMirrorFrame in",
            to: "session.onReadyToDisplay = { [weak self, weak session] in"
        )
        let recoverBody = try sourceSlice(
            in: source,
            from: "private func recoverMissingMirrorTransport()",
            to: "private func launchNativeMirror("
        )

        XCTAssertTrue(stopBody.contains("restorePresentationModeIfNeeded()"))
        XCTAssertTrue(sessionEndedBody.contains("restorePresentationModeIfNeeded()"))
        XCTAssertTrue(recoverBody.contains("restorePresentationModeIfNeeded()"))
    }

    func testUSBWiFiHandoffPersistsOnlyAfterReadinessCompletes() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )
        let candidateBody = try sourceSlice(
            in: source,
            from: "private func rememberUSBWiFiHandoffCandidate(",
            to: "/// \"No route to host\" on every attempt"
        )
        let finishBody = try sourceSlice(
            in: source,
            from: "private func finishWirelessHandoff(",
            to: "func connectViaUSB()"
        )

        XCTAssertFalse(candidateBody.contains("touchPairedPhone("))
        XCTAssertTrue(finishBody.contains("touchPairedPhone("))
    }

    func testFailedUSBWiFiTakeoverEndsLoadingState() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )
        let failureBody = try sourceSlice(
            in: source,
            from: "Logger.log(\"Prepared Wi-Fi handoff address=\\(candidate.address) was not ready after USB ended\")",
            to: "        }\n        return true"
        )
        let takeoverBody = try sourceSlice(
            in: source,
            from: "private func startUSBWiFiHandoffTakeoverIfAvailable(",
            to: "    private func recoverUSBLaunchFailureOverWireless"
        )

        XCTAssertTrue(failureBody.contains("self.isRecoveringConnection = false"))
        XCTAssertTrue(failureBody.contains("self.isAwaitingReconnect = false"))
        XCTAssertTrue(failureBody.contains("self.stopQRCodePairingSession()"))
        XCTAssertTrue(failureBody.contains("self.selectedDevice.adbSerial = candidate.usbSerial"))
        XCTAssertTrue(failureBody.contains("self.selectedDevice.network = \"USB\""))
        XCTAssertTrue(failureBody.contains("keepConnectionWindowVisibleOverride: false"))
        XCTAssertFalse(failureBody.contains("startDisconnectRecoveryFallback()"))
        XCTAssertTrue(takeoverBody.contains("showConnectionWindow(startsQRCodePairing: false)"))
    }

    private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw XCTSkip("Missing source start marker: \(start)")
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw XCTSkip("Missing source end marker: \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
