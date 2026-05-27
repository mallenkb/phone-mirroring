import SwiftUI
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedDevice: MirrorDevice = .demo
    @Published var diagnostics: [DiagnosticLine] = [
        DiagnosticLine(date: .now, message: "Prototype ready. Connect an Android phone with USB debugging or wireless debugging, then scan for adb devices.")
    ]
    @Published var isScanning = false
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var isPairing = false
    @Published var connectionScale: CGFloat = 0.56

    @Published private(set) var discoveredPhones: [DiscoveredPhone] = []
    @Published private(set) var pairedPhones: [PairedPhoneRecord] = []

    private let adb = ADBController()
    private let scrcpy = ScrcpyController()
    private let store = PairedPhoneStore()
    private lazy var discovery = DiscoveryService(adb: adb)

    private weak var connectionWindow: NSWindow?
    private(set) weak var mirrorWindowController: WindowController?
    private var mirrorFrameWindowController: MirrorFrameWindowController?
    private var mirrorSession: MirrorSession?
    private var mirrorDragStartFrame: CGRect?
    private var mirrorExpandedRestoreFrame: CGRect?
    private var autoConnectAttempted = false

    init() {
        pairedPhones = store.load()
        discovery.start { [weak self] phones in
            self?.discoveredPhones = phones
        }
        attemptAutoReconnect()
    }

    // MARK: - Window registration

    func registerConnectionWindow(_ window: NSWindow?) {
        guard let window else { return }
        connectionWindow = window
    }

    func registerMirrorWindowController(_ controller: WindowController?) {
        mirrorWindowController = controller
        registerConnectionWindow(controller?.window)
    }

    // MARK: - Discovery → auto-reconnect

    /// On launch, give mDNS a few seconds; if a previously-paired phone shows
    /// up, or a remembered USB serial is authorized, mirror it immediately.
    /// Bluetooth-style auto-reconnect.
    private func attemptAutoReconnect() {
        guard !pairedPhones.isEmpty else { return }
        let adb = self.adb
        Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.autoConnectAttempted || self.isMirroring { return }

                let devicesOutput = await Task.detached { adb.run(["devices", "-l"]) }.value
                let authorizedDevices = Self.authorizedADBDevices(in: devicesOutput)

                let rememberedWireless = Self.mostRecentWirelessRecord(in: self.pairedPhones)
                if let rememberedWireless {
                    let connectOutput = await Task.detached {
                        adb.run(["connect", rememberedWireless.lastAddress])
                    }.value
                    if Self.adbConnectSucceeded(connectOutput) {
                        self.autoConnectAttempted = true
                        self.append("adb connect: \(Self.oneLine(connectOutput))")
                        self.select(record: rememberedWireless)
                        self.touchPairedPhone(
                            id: rememberedWireless.id,
                            displayName: rememberedWireless.displayName,
                            address: rememberedWireless.lastAddress
                        )
                        self.startMirroring()
                        return
                    }
                }

                let livePhones = await Task.detached { adb.connectableMDNSTargets() }.value
                let candidate = self.mostRecentPairedPhone(in: livePhones + self.discoveredPhones)
                if let candidate {
                    self.autoConnectAttempted = true
                    self.connectAndMirror(phone: candidate)
                    return
                }

                let rememberedUSB = authorizedDevices.first { device in
                    device.isUSB && self.pairedPhones.contains(where: { $0.id == device.serial })
                }
                if let rememberedUSB {
                    self.autoConnectAttempted = true
                    self.select(device: rememberedUSB)
                    self.touchPairedPhone(
                        id: rememberedUSB.serial,
                        displayName: rememberedUSB.model,
                        address: rememberedUSB.serial
                    )
                    self.startMirroring()
                    return
                }
            }
        }
    }

    private func connectAndMirror(phone: DiscoveredPhone) {
        let address = phone.address
        let serviceID = phone.id
        let label = displayName(for: phone)
        append("Connecting to \(label) at \(address)...")

        let adb = self.adb
        Task { [weak self] in
            await adb.restartServer()
            let output = await Task.detached { adb.run(["connect", address]) }.value

            guard let self else { return }
            self.append("adb connect: \(Self.oneLine(output))")
            let lower = output.lowercased()
            let ok = lower.contains("connected") || lower.contains("already")
            if ok {
                self.touchPairedPhone(id: serviceID, displayName: label, address: address)
                self.selectedDevice.adbSerial = address
                self.startMirroring()
            } else {
                self.append("Could not reach \(address). Re-pair from the Wireless debugging screen.")
            }
        }
    }

    private func touchPairedPhone(id: String, displayName: String, address: String) {
        pairedPhones = store.touch(pairedPhones, id: id, displayName: displayName, address: address)
        store.save(pairedPhones)
    }

    private func displayName(for phone: DiscoveredPhone) -> String {
        pairedPhones.first(where: { $0.id == phone.id })?.displayName ?? "Android device"
    }

    // MARK: - Scan / pair flows

    func scanADBDevices() {
        isScanning = true
        append("Scanning adb devices...")
        let adb = self.adb
        Task { [weak self] in
            let output = await Task.detached { adb.run(["devices", "-l"]) }.value
            guard let self else { return }
            self.isScanning = false
            self.applyADBOutput(output)
        }
    }

    func autoPairWirelessly() {
        guard !isMirroring else { return }
        append("Preparing wireless mirror...")
        isPairing = true

        let adb = self.adb
        Task { [weak self] in
            let devicesOutput = await Task.detached { adb.run(["devices", "-l"]) }.value
            let lines = devicesOutput.split(whereSeparator: \.isNewline).map(String.init)
            let hasUnauthorizedUSB = lines.contains { $0.contains("unauthorized") && $0.contains("usb:") }
            let usbDevice = Self.authorizedADBDevices(in: devicesOutput).first(where: \.isUSB)

            guard let self else { return }

            if hasUnauthorizedUSB {
                self.isPairing = false
                self.append("Phone is connected by cable, but Android has not authorized this Mac yet. Unlock the phone, accept the USB debugging prompt, then try the wireless handoff again.")
                return
            }

            if let usbDevice {
                self.select(device: usbDevice)
                self.touchPairedPhone(
                    id: usbDevice.serial,
                    displayName: usbDevice.model,
                    address: usbDevice.serial
                )
                self.append("USB phone authorized. Switching \(usbDevice.model) to Wi-Fi...")

                let routeOutput = await Task.detached {
                    adb.run(["-s", usbDevice.serial, "shell", "ip", "route"])
                }.value
                let usbWiFiAddress = Self.wifiIPAddress(in: routeOutput).map { "\($0):5555" }

                let tcpipOutput = await Task.detached {
                    adb.run(["-s", usbDevice.serial, "tcpip", "5555"])
                }.value
                self.append("adb tcpip: \(Self.oneLine(tcpipOutput))")

                guard Self.adbTCPIPSucceeded(tcpipOutput) else {
                    self.isPairing = false
                    self.append("Could not switch to Wi-Fi. Starting USB mirror instead.")
                    self.startMirroring()
                    return
                }

                let wirelessPhone = await Self.waitForConnectableWirelessPhone(
                    adb: adb,
                    preferredAddress: usbWiFiAddress
                )

                guard let wirelessPhone else {
                    self.isPairing = false
                    self.append("Wi-Fi adb did not appear. Starting USB mirror instead.")
                    self.startMirroring()
                    return
                }

                let connectOutput = await Task.detached {
                    adb.run(["connect", wirelessPhone.address])
                }.value
                self.append("adb connect: \(Self.oneLine(connectOutput))")

                self.isPairing = false
                guard Self.adbConnectSucceeded(connectOutput) else {
                    self.append("Could not connect over Wi-Fi. Starting USB mirror instead.")
                    self.startMirroring()
                    return
                }

                self.touchPairedPhone(
                    id: wirelessPhone.id,
                    displayName: usbDevice.model,
                    address: wirelessPhone.address
                )
                self.selectedDevice.adbSerial = wirelessPhone.address
                self.selectedDevice.network = "Wireless debugging"
                self.append("Wireless mirror ready. You can unplug the cable.")
                self.startMirroring()
                return
            }

            for record in Self.wirelessRecordsByMostRecent(self.pairedPhones) {
                let connectOutput = await Task.detached { adb.run(["connect", record.lastAddress]) }.value
                self.append("adb connect \(record.lastAddress): \(Self.oneLine(connectOutput))")
                if Self.adbConnectSucceeded(connectOutput) {
                    self.isPairing = false
                    self.select(record: record)
                    self.touchPairedPhone(
                        id: record.id,
                        displayName: record.displayName,
                        address: record.lastAddress
                    )
                    self.startMirroring()
                    return
                }
            }

            let target = await Task.detached { adb.firstMDNSTarget(type: "_adb-tls-connect._tcp") }.value

            guard let target else {
                self.isPairing = false
                self.append("No cable, saved Wi-Fi route, or wireless adb service found. Plug in once, accept the Android USB debugging prompt, then try again.")
                return
            }

            let connectOutput = await Task.detached { adb.run(["connect", target]) }.value

            self.isPairing = false
            self.append("adb connect: \(Self.oneLine(connectOutput))")
            guard Self.adbConnectSucceeded(connectOutput) else { return }
            self.selectedDevice.adbSerial = target
            self.startMirroring()
        }
    }

    private func mostRecentPairedPhone(in phones: [DiscoveredPhone]) -> DiscoveredPhone? {
        let recordsByID = Dictionary(uniqueKeysWithValues: pairedPhones.map { ($0.id, $0) })
        return phones
            .filter { $0.kind == .connectable && recordsByID[$0.id] != nil }
            .sorted {
                let lhs = recordsByID[$0.id]?.lastConnected ?? .distantPast
                let rhs = recordsByID[$1.id]?.lastConnected ?? .distantPast
                return lhs > rhs
            }
            .first
    }

    private func applyADBOutput(_ output: String) {
        guard let first = Self.authorizedADBDevices(in: output).first else {
            selectedDevice.states = [.wirelessDebuggingRequired, .usbAuthorizationRequired, .companionConnected]
            append("No authorized adb device found. Connect USB, authorize debugging on Android, or use wireless debugging.")
            return
        }

        select(device: first)
        append("Authorized adb device found: \(first.model) (\(first.serial)).")
    }

    private func select(device: AuthorizedADBDevice) {
        selectedDevice = MirrorDevice(
            id: device.serial,
            name: device.model,
            model: device.product,
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: device.isUSB ? "USB debugging" : "Wireless debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: device.serial
        )
    }

    private func select(record: PairedPhoneRecord) {
        selectedDevice = MirrorDevice(
            id: record.id,
            name: record.displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: "Wireless debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: record.lastAddress
        )
    }

    nonisolated static func authorizedADBDevices(in output: String) -> [AuthorizedADBDevice] {
        output
            .split(separator: "\n")
            .dropFirst()
            .map(String.init)
            .filter { line in
                line.contains("device")
                    && !line.contains("offline")
                    && !line.contains("unauthorized")
            }
            .compactMap { line in
                guard let serial = line.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
                    return nil
                }
                let product = value(after: "product:", in: line) ?? "Android"
                let model = value(after: "model:", in: line)?
                    .replacingOccurrences(of: "_", with: " ") ?? "Authorized Device"
                return AuthorizedADBDevice(
                    serial: serial,
                    product: product,
                    model: model,
                    isUSB: line.contains("usb:")
                )
            }
    }

    nonisolated static func adbConnectSucceeded(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("connected to ") || lower.contains("already connected to ")
    }

    nonisolated static func adbTCPIPSucceeded(_ output: String) -> Bool {
        output.lowercased().contains("restarting in tcp mode port:")
    }

    nonisolated static func mostRecentWirelessRecord(in records: [PairedPhoneRecord]) -> PairedPhoneRecord? {
        wirelessRecordsByMostRecent(records).first
    }

    nonisolated static func wirelessRecordsByMostRecent(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records
            .filter { $0.lastAddress.contains(":") }
            .sorted { $0.lastConnected > $1.lastConnected }
    }

    nonisolated static func wifiIPAddress(in routeOutput: String) -> String? {
        for line in routeOutput.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.contains("wlan"), line.contains(" src ") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let srcIndex = parts.firstIndex(of: "src"),
                  parts.indices.contains(srcIndex + 1)
            else { continue }
            return parts[srcIndex + 1]
        }
        return nil
    }

    private static func waitForConnectableWirelessPhone(
        adb: ADBController,
        preferredAddress: String?
    ) async -> DiscoveredPhone? {
        for _ in 0..<8 {
            if let preferredAddress {
                let connectOutput = await Task.detached { adb.run(["connect", preferredAddress]) }.value
                if adbConnectSucceeded(connectOutput) {
                    return DiscoveredPhone(
                        id: preferredAddress,
                        address: preferredAddress,
                        kind: .connectable,
                        lastSeen: .now
                    )
                }
            }

            let phones = await Task.detached { adb.connectableMDNSTargets() }.value
            if let phone = phones.first {
                return phone
            }
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        return nil
    }

    private nonisolated static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        return tail.split(separator: " ").first.map(String.init)
    }

    // MARK: - Mirroring lifecycle

    func startMirroring() {
        guard !isMirroring else { return }
        let serial = selectedDevice.adbSerial
        append(serial == nil ? "Starting native mirror..."
                              : "Starting native mirror for \(serial!)...")
        launchNativeMirror(serial: serial)
    }

    func stopMirroring() {
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        scrcpy.stop()
        isMirroring = false
        detachMirrorChrome()
        append("Requested mirror stop.")
    }

    private func launchNativeMirror(serial: String?) {
        let session = MirrorSession(model: self, serial: serial)
        session.onSessionEnded = { [weak self, weak session] in
            guard let self else { return }
            if self.mirrorSession === session {
                self.mirrorSession = nil
            }
            self.isMirroring = false
            self.detachMirrorChrome()
            self.append("Mirror session ended.")
        }

        do {
            mirrorSession = session
            isMirroring = true
            selectedDevice.states = [.mirroringReady, .companionConnected]
            try session.start()
            hideConnectionWindowForNativeMirror()
            append("Native mirror launched.")
        } catch {
            session.onSessionEnded = nil
            session.stop()
            if mirrorSession === session {
                mirrorSession = nil
            }
            isMirroring = false
            append("Could not launch native mirror: \(error.localizedDescription)")
        }
    }

    private func launchScrcpy(arguments: [String]) {
        do {
            let pid = try scrcpy.launch(extraArguments: arguments) { [weak self] output in
                guard let self else { return }
                self.scrcpy.clear()
                self.detachMirrorChrome()
                self.isMirroring = false
                if output.contains("No route to host") {
                    self.append("Wireless handoff failed because Wi-Fi blocked the phone. Falling back to USB mirror.")
                    if arguments.contains(where: { $0.contains("--tcpip") }) {
                        self.launchScrcpy(arguments: ["-d"])
                    }
                } else if output.contains("Could not connect") || output.contains("Server connection failed") {
                    self.append("scrcpy failed: \(Self.oneLine(output))")
                } else {
                    self.append("Mirror session ended.")
                }
            }
            isMirroring = true
            selectedDevice.states = [.mirroringReady, .companionConnected]
            attachMirrorChrome(pid: pid)
            append("scrcpy launched with \(arguments.joined(separator: " ")).")
        } catch {
            append("Could not launch scrcpy: \(error.localizedDescription)")
        }
    }

    // MARK: - Mirror window chrome (toolbar + frame)

    private func attachMirrorChrome(pid: pid_t) {
        detachMirrorChrome(reopenConnectionWindow: false)
        mirrorFrameWindowController = MirrorFrameWindowController(model: self, scrcpyPid: pid)
        hideConnectionWindowForLiveMirror(pid: pid)
    }

    private func detachMirrorChrome(reopenConnectionWindow: Bool = true) {
        mirrorFrameWindowController?.close()
        mirrorFrameWindowController = nil
        mirrorDragStartFrame = nil
        mirrorExpandedRestoreFrame = nil
        if isRecording {
            stopScreenRecordingCleanup()
        }
        if reopenConnectionWindow {
            showConnectionWindow()
        }
    }

    func closeMirrorWindow() {
        stopMirroring()
    }

    func minimizeMirrorWindow() {
        if mirrorSession != nil {
            connectionWindow?.miniaturize(nil)
            return
        }
        guard let pid = scrcpy.activePid else { return }
        guard ensureMirrorAccessibility(for: "minimize the mirror") else { return }

        let result = ScrcpyController.setWindowMinimized(pid: pid, minimized: true)
        if result != .success {
            NSRunningApplication(processIdentifier: pid)?.hide()
            append("Minimized the mirror process. If it does not appear in the Dock, use Start Mirroring again.")
        }
    }

    func toggleMirrorFullscreen() {
        if mirrorSession != nil {
            connectionWindow?.toggleFullScreen(nil)
            return
        }
        guard let pid = scrcpy.activePid else {
            resizeConnectionWindow(scale: 1.10)
            return
        }
        guard ensureMirrorAccessibility(for: "expand the mirror") else { return }

        let targetFrame: CGRect
        let restoreFrame = mirrorExpandedRestoreFrame
        let restoreCandidate: CGRect?
        if let restoreFrame {
            targetFrame = restoreFrame
            restoreCandidate = nil
        } else {
            guard let bounds = ScrcpyController.windowBounds(pid: pid) else {
                append("Mirror window is still opening. Try again in a moment.")
                return
            }
            restoreCandidate = bounds
            guard let primary = NSScreen.screens.first else { return }
            let screenHeight = primary.frame.height
            let scrcpyNSPoint = NSPoint(x: bounds.midX, y: screenHeight - bounds.midY)
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(scrcpyNSPoint) }) ?? primary
            targetFrame = MirrorWindowChromeLayout.expandedScrcpyFrame(
                from: bounds,
                inVisibleFrame: targetScreen.visibleFrame,
                screenHeight: screenHeight,
                chromeHeight: 0,
                padding: 12
            )
        }

        let result = ScrcpyController.setWindowFrame(pid: pid, frame: targetFrame)
        if result == .success {
            if restoreFrame == nil {
                mirrorExpandedRestoreFrame = restoreCandidate
            } else {
                mirrorExpandedRestoreFrame = nil
            }
        } else {
            append("Could not expand the mirror window yet (\(result)). Check Accessibility permission for Android Mirror.")
        }
    }

    func beginMirrorWindowDrag() {
        guard let pid = scrcpy.activePid else { return }
        guard ensureMirrorAccessibility(for: "drag the mirror") else { return }
        mirrorExpandedRestoreFrame = nil
        mirrorDragStartFrame = ScrcpyController.windowBounds(pid: pid)
        if mirrorDragStartFrame == nil {
            append("Mirror window is still opening. Try again in a moment.")
        }
    }

    @discardableResult
    func dragMirrorWindow(translation: CGSize) -> CGSize? {
        guard let pid = scrcpy.activePid,
              let startFrame = mirrorDragStartFrame else { return nil }

        let proposedFrame = CGRect(
            x: startFrame.minX + translation.width,
            y: startFrame.minY + translation.height,
            width: startFrame.width,
            height: startFrame.height
        )
        let frame = constrainedMirrorDragFrame(proposedFrame)
        let result = ScrcpyController.setWindowFrame(pid: pid, frame: frame)
        if result != .success {
            mirrorDragStartFrame = nil
            append("Could not drag the mirror window yet (\(result)). Check Accessibility permission for Android Mirror.")
            return nil
        }

        return CGSize(
            width: frame.minX - startFrame.minX,
            height: frame.minY - startFrame.minY
        )
    }

    func endMirrorWindowDrag() {
        mirrorDragStartFrame = nil
    }

    private func constrainedMirrorDragFrame(_ proposedFrame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return proposedFrame }
        let screenHeight = primary.frame.height
        let proposedNSPoint = NSPoint(
            x: proposedFrame.midX,
            y: screenHeight - proposedFrame.midY
        )
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(proposedNSPoint) }) ?? primary
        return MirrorWindowChromeLayout.scrcpyFrameKeepingHoverChromeVisible(
            proposedFrame,
            inVisibleFrame: targetScreen.visibleFrame,
            screenHeight: screenHeight,
            chromeHeight: MirrorFrameWindowController.chromeHeight
        )
    }

    private func ensureMirrorAccessibility(for action: String) -> Bool {
        guard ScrcpyController.requestAccessibilityTrustIfNeeded() else {
            append("Turn on Android Mirror in System Settings > Privacy & Security > Accessibility, then \(action) again.")
            return false
        }
        return true
    }

    private func hideConnectionWindowForLiveMirror(pid: pid_t) {
        connectionWindow?.orderOut(nil)
        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func hideConnectionWindowForNativeMirror() {
        connectionWindow?.close()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showConnectionWindow() {
        guard let connectionWindow else { return }
        connectionWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Resize

    func resizeMirror(scale: CGFloat) {
        if let mirrorSession {
            mirrorSession.scaleWindow(by: scale)
            return
        }

        guard let pid = scrcpy.activePid else {
            resizeConnectionWindow(scale: scale)
            return
        }

        guard let bounds = ScrcpyController.windowBounds(pid: pid) else {
            append("Mirror window is still opening. Try again in a moment.")
            return
        }

        guard ScrcpyController.requestAccessibilityTrustIfNeeded() else {
            append("Turn on Android Mirror in System Settings > Privacy & Security > Accessibility, then press + or - again.")
            return
        }

        let minWidth: CGFloat = 260
        let screenMaxWidth = NSScreen.screens.first?.visibleFrame.width ?? 1200
        let maxWidth = min(screenMaxWidth - 48, 1100)
        let newWidth = min(max(bounds.width * scale, minWidth), maxWidth)
        let newHeight = newWidth * bounds.height / max(bounds.width, 1)
        let newX = bounds.midX - newWidth / 2
        let newY = bounds.midY - newHeight / 2

        let result = ScrcpyController.setWindowFrame(
            pid: pid,
            frame: CGRect(x: newX, y: newY, width: newWidth, height: newHeight)
        )
        if result != .success {
            append("Could not resize the mirror window yet (\(result)). You can also drag the mirror window edge directly.")
        }
    }

    private func resizeConnectionWindow(scale: CGFloat) {
        guard let window = connectionWindow else { return }

        let frame = window.frame
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let minWidth: CGFloat = 257
        let minHeight: CGFloat = 574
        let maxWidth = max(minWidth, (visible?.width ?? 1200) - 40)
        let maxHeight = max(minHeight, (visible?.height ?? 1400) - 40)
        let newWidth = min(max(frame.width * scale, minWidth), maxWidth)
        let newHeight = min(max(frame.height * scale, minHeight), maxHeight)
        let newFrame = NSRect(
            x: frame.midX - newWidth / 2,
            y: frame.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )

        connectionScale = min(max(newWidth / 918, 0.32), 1.30)
        window.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Android input

    func sendAndroidKey(_ keycode: String) {
        let adb = self.adb
        Task.detached {
            adb.run(["shell", "input", "keyevent", keycode])
        }
    }

    func takeScreenshot() {
        append("Saving screenshot to Desktop...")
        Task { [weak self] in
            let result = await Task.detached { () -> Result<Void, ScreenshotError> in
                guard let adbPath = Tooling.toolPath(named: "adb") else {
                    return .failure(.adbMissing)
                }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = ["exec-out", "screencap", "-p"]
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard !data.isEmpty else {
                        return .failure(.emptyOutput)
                    }
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/android-mirror-screenshot.png")
                    try data.write(to: url)
                    return .success(())
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            guard let self else { return }
            switch result {
            case .success:
                self.append("Saved screenshot to Desktop.")
            case .failure(.adbMissing):
                self.append("adb is missing.")
            case .failure(.emptyOutput):
                self.append("Screenshot was empty. Is the phone authorized?")
            case .failure(.runtime(let message)):
                self.append("Screenshot failed: \(message)")
            }
        }
    }

    private enum ScreenshotError: Error {
        case adbMissing
        case emptyOutput
        case runtime(String)
    }

    func toggleScreenRecording() {
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        } else {
            isRecording = true
            append("Started Android screen recording.")
            let adb = self.adb
            Task.detached {
                adb.run([
                    "shell",
                    "rm -f /sdcard/android-mirror-record.mp4; screenrecord /sdcard/android-mirror-record.mp4 >/dev/null 2>&1 &"
                ])
            }
        }
    }

    private func stopScreenRecordingCleanup() {
        append("Stopping Android screen recording...")
        let adb = self.adb
        Task { [weak self] in
            await Task.detached {
                _ = adb.run(["shell", "pkill -2 screenrecord >/dev/null 2>&1"])
            }.value
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            await Task.detached {
                _ = adb.run([
                    "pull", "/sdcard/android-mirror-record.mp4",
                    "\(home)/Desktop/android-mirror-record.mp4"
                ])
                _ = adb.run(["shell", "rm -f /sdcard/android-mirror-record.mp4 >/dev/null 2>&1"])
            }.value
            self?.append("Saved screen recording to Desktop.")
        }
    }

    // MARK: - Diagnostics

    private func append(_ message: String) {
        Logger.log("Diagnostic: \(message)")
        diagnostics.insert(DiagnosticLine(date: .now, message: message), at: 0)
        diagnostics = Array(diagnostics.prefix(8))
    }

    static func oneLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
