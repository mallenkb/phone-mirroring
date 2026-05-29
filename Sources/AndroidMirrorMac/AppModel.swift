import SwiftUI
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedDevice: MirrorDevice = .demo
    @Published var diagnostics: [DiagnosticLine] = []
    @Published var isScanning = false
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var isPairing = false
    @Published var captureCue: CaptureCue?
    static let onboardingWindowSize = NSSize(width: 500, height: 900)
    static let minimumConnectionWindowSize = NSSize(width: 384, height: 688)
    static let defaultConnectionWindowSize = NSSize(width: 650, height: 1170)

    @Published private(set) var discoveredPhones: [DiscoveredPhone] = []
    @Published private(set) var pairedPhones: [PairedPhoneRecord] = []
    @Published private(set) var qrPairingSession: ADBQRCodePairingSession?
    @Published private(set) var isQRCodePairingWaiting = false

    private let adb = ADBController()
    private let store = PairedPhoneStore()
    private lazy var discovery = DiscoveryService(adb: adb)

    private weak var connectionWindow: NSWindow?
    private var mirrorSession: MirrorSession?
    private var autoConnectAttempted = false
    private var usbHandoffTask: Task<Void, Never>?
    private var lastUSBHandoffSerial: String?
    private var qrPairingTask: Task<Void, Never>?
    private var screenRecordingMonitorTask: Task<Void, Never>?

    enum CaptureCueKind: Equatable {
        case screenshot
        case recordingStarted
        case recordingStopped
    }

    struct CaptureCue: Equatable, Identifiable {
        let id = UUID()
        let kind: CaptureCueKind

        var title: String {
            switch kind {
            case .screenshot: return "Screenshot captured"
            case .recordingStarted: return "Recording started"
            case .recordingStopped: return "Recording saved"
            }
        }

        var symbolName: String {
            switch kind {
            case .screenshot: return "camera.fill"
            case .recordingStarted: return "record.circle.fill"
            case .recordingStopped: return "checkmark.circle.fill"
            }
        }
    }

    init() {
        pairedPhones = store.load()
        if let mostRecentRecord = Self.recordsByMostRecent(pairedPhones).first {
            select(record: mostRecentRecord)
        }
        discovery.start { [weak self] phones in
            self?.discoveredPhones = phones
        }
        startUSBHandoffWatcher()
        attemptAutoReconnect()
    }

    deinit {
        usbHandoffTask?.cancel()
        qrPairingTask?.cancel()
        screenRecordingMonitorTask?.cancel()
    }

    // MARK: - Window registration

    func registerConnectionWindow(_ window: NSWindow?) {
        guard let window else { return }
        connectionWindow = window
    }

    // MARK: - Discovery → auto-reconnect

    /// On launch, try saved adb routes immediately; if needed, give mDNS a few
    /// seconds for a previously-paired phone to advertise its connect service.
    /// Bluetooth-style auto-reconnect.
    private func attemptAutoReconnect() {
        guard !pairedPhones.isEmpty else { return }
        let adb = self.adb
        Task { [weak self] in
            for attempt in 0..<6 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let self else { return }
                if self.autoConnectAttempted || self.isMirroring || self.isPairing {
                    return
                }

                let devicesOutput = await Task.detached { adb.run(["devices", "-l"]) }.value
                let authorizedDevices = Self.authorizedADBDevices(in: devicesOutput)

                if let authorizedDevice = authorizedDevices.first {
                    self.autoConnectAttempted = true
                    self.select(device: authorizedDevice)
                    self.touchPairedPhone(
                        id: authorizedDevice.serial,
                        displayName: authorizedDevice.model,
                        address: authorizedDevice.serial
                    )
                    self.stopQRCodePairingSession()
                    self.startMirroring()
                    return
                }

                for record in Self.recordsByMostRecent(self.pairedPhones) {
                    if Self.isWirelessRecord(record) {
                        let connectOutput = await Task.detached {
                            adb.run(["connect", record.lastAddress])
                        }.value
                        if Self.adbConnectSucceeded(connectOutput) {
                            self.autoConnectAttempted = true
                            self.append("adb connect: \(Self.oneLine(connectOutput))")
                            self.select(record: record)
                            self.touchPairedPhone(
                                id: record.id,
                                displayName: record.displayName,
                                address: record.lastAddress
                            )
                            self.stopQRCodePairingSession()
                            self.startMirroring()
                            return
                        }
                    } else if let rememberedUSB = authorizedDevices.first(where: { device in
                        device.isUSB && (device.serial == record.id || device.serial == record.lastAddress)
                    }) {
                        self.autoConnectAttempted = true
                        self.select(device: rememberedUSB)
                        self.touchPairedPhone(
                            id: rememberedUSB.serial,
                            displayName: rememberedUSB.model,
                            address: rememberedUSB.serial
                        )
                        self.stopQRCodePairingSession()
                        self.startMirroring()
                        return
                    }
                }

                let livePhones = await Task.detached { adb.connectableMDNSTargets() }.value
                let candidate = self.mostRecentPairedPhone(in: livePhones + self.discoveredPhones)
                if let candidate {
                    self.autoConnectAttempted = true
                    self.stopQRCodePairingSession()
                    self.connectAndMirror(phone: candidate)
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
                self.stopQRCodePairingSession()
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

    private func startUSBHandoffWatcher() {
        guard usbHandoffTask == nil else { return }
        let adb = self.adb
        usbHandoffTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let output = await Task.detached { adb.run(["devices", "-l"]) }.value

                guard let self else { return }
                guard !self.isMirroring, !self.isPairing, !self.isQRCodePairingWaiting else {
                    continue
                }

                guard let usbDevice = Self.usbHandoffCandidate(
                    in: output,
                    lastAttemptedSerial: self.lastUSBHandoffSerial
                ) else {
                    if Self.authorizedADBDevices(in: output).first(where: \.isUSB) == nil {
                        self.lastUSBHandoffSerial = nil
                    }
                    continue
                }

                self.lastUSBHandoffSerial = usbDevice.serial
                self.isPairing = true
                self.append("USB phone authorized. Looking for Wireless debugging over Wi-Fi...")
                await self.prepareWirelessMirror(
                    from: usbDevice,
                    allowLegacyTCPIPFallback: false
                )
            }
        }
    }

    func ensureQRCodePairingSession() {
        guard !isMirroring else { return }
        if qrPairingSession == nil {
            qrPairingSession = .random()
        }
        startQRCodePairingWatcher()
    }

    func restartQRCodePairingSession() {
        guard !isMirroring else { return }
        qrPairingTask?.cancel()
        qrPairingTask = nil
        isQRCodePairingWaiting = false
        qrPairingSession = .random()
        startQRCodePairingWatcher()
    }

    func stopQRCodePairingSession() {
        let hadPairingTask = qrPairingTask != nil
        qrPairingTask?.cancel()
        qrPairingTask = nil
        isQRCodePairingWaiting = false
        if hadPairingTask && isPairing {
            isPairing = false
        }
    }

    private func startQRCodePairingWatcher() {
        guard qrPairingTask == nil,
              let session = qrPairingSession
        else { return }

        isQRCodePairingWaiting = true

        let adb = self.adb
        qrPairingTask = Task { [weak self] in
            await adb.restartServer()
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                let phones = await Task.detached { adb.mdnsServices() }.value
                guard !Task.isCancelled else { return }

                guard let self else { return }
                guard self.qrPairingSession == session else { return }

                guard let pairingPhone = ADBQRCodePairingSession.pairingService(
                    named: session.serviceName,
                    in: phones
                ) else {
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    continue
                }

                self.isQRCodePairingWaiting = false
                self.isPairing = true
                self.append("QR code scanned. Pairing with wireless debugging...")

                let pairOutput = await Task.detached {
                    adb.run(["pair", pairingPhone.address, session.password])
                }.value
                guard !Task.isCancelled else { return }
                self.append("adb pair: \(Self.oneLine(pairOutput))")

                guard Self.adbPairSucceeded(pairOutput) else {
                    self.resetQRCodePairingAfterFailure(
                        "QR pairing failed. Scan the new code and try again."
                    )
                    return
                }

                guard let connectablePhone = await Self.waitForConnectableWirelessPhone(
                    adb: adb,
                    preferredAddress: nil,
                    matchingHostOf: pairingPhone.address
                ) else {
                    guard !Task.isCancelled else { return }
                    self.resetQRCodePairingAfterFailure(
                        "Paired, but no wireless debugging connect service appeared. Scan the new code and try again."
                    )
                    return
                }
                guard !Task.isCancelled else { return }

                let connectOutput = await Task.detached {
                    adb.run(["connect", connectablePhone.address])
                }.value
                guard !Task.isCancelled else { return }
                self.append("adb connect: \(Self.oneLine(connectOutput))")

                guard Self.adbConnectSucceeded(connectOutput) else {
                    self.resetQRCodePairingAfterFailure(
                        "Paired, but could not connect to \(connectablePhone.address). Scan the new code and try again."
                    )
                    return
                }

                self.finishQRCodePairing(with: connectablePhone)
                return
            }
        }
    }

    private func resetQRCodePairingAfterFailure(_ message: String) {
        isPairing = false
        isQRCodePairingWaiting = false
        qrPairingTask = nil
        qrPairingSession = .random()
        append(message)
        startQRCodePairingWatcher()
    }

    private func finishQRCodePairing(with phone: DiscoveredPhone) {
        isPairing = false
        isQRCodePairingWaiting = false
        qrPairingTask = nil
        qrPairingSession = nil
        touchPairedPhone(
            id: phone.id,
            displayName: "Android device",
            address: phone.address
        )
        selectedDevice = MirrorDevice(
            id: phone.id,
            name: "Android device",
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: "Wireless debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: phone.address
        )
        append("QR pairing complete. Starting wireless mirror.")
        startMirroring()
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
                await self.prepareWirelessMirror(
                    from: usbDevice,
                    allowLegacyTCPIPFallback: true
                )
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

    private func prepareWirelessMirror(
        from usbDevice: AuthorizedADBDevice,
        allowLegacyTCPIPFallback: Bool
    ) async {
        select(device: usbDevice)
        touchPairedPhone(
            id: usbDevice.serial,
            displayName: usbDevice.model,
            address: usbDevice.serial
        )
        append("USB phone authorized. Checking \(usbDevice.model)'s wireless debugging endpoint...")

        let adb = self.adb
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"])
        }.value

        let tlsPortOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "getprop", "service.adb.tls.port"])
        }.value
        let tcpPortOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "getprop", "service.adb.tcp.port"])
        }.value
        if let tlsAddress = Self.wirelessDebuggingAddress(
            routeOutput: routeOutput,
            tlsPortOutput: tlsPortOutput,
            tcpPortOutput: tcpPortOutput
        ) {
            append("Wireless debugging endpoint found over USB at \(tlsAddress).")
            let connectOutput = await Task.detached {
                adb.run(["connect", tlsAddress])
            }.value
            append("adb connect: \(Self.oneLine(connectOutput))")

            if Self.adbConnectSucceeded(connectOutput) {
                isPairing = false
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    wirelessID: tlsAddress,
                    address: tlsAddress
                )
                return
            }

            append("Wireless debugging endpoint did not accept this Mac. If this is the first time, use Wi-Fi and scan a pairing QR code.")
        }

        let discoveredWirelessPhones = await Task.detached {
            adb.connectableMDNSTargets()
        }.value
        if let wirelessPhone = Self.wirelessPhoneMatchingUSBRoute(
            routeOutput,
            phones: discoveredWirelessPhones
        ) {
            append("Wireless adb service found at \(wirelessPhone.address).")
            let connectOutput = await Task.detached {
                adb.run(["connect", wirelessPhone.address])
            }.value
            append("adb connect: \(Self.oneLine(connectOutput))")

            if Self.adbConnectSucceeded(connectOutput) {
                isPairing = false
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    wirelessID: wirelessPhone.id,
                    address: wirelessPhone.address
                )
                return
            }

            append("Wireless service did not connect.")
        }

        guard allowLegacyTCPIPFallback else {
            isPairing = false
            append("USB is ready, but no paired Wireless debugging endpoint was available. Use Wi-Fi and scan a pairing QR code, or press Wi-Fi to force the USB cable handoff.")
            return
        }

        append("Trying USB cable handoff on port 5555...")
        let usbWiFiAddress = Self.wifiIPAddress(in: routeOutput).map { "\($0):5555" }

        let tcpipOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "tcpip", "5555"])
        }.value
        append("adb tcpip: \(Self.oneLine(tcpipOutput))")

        guard Self.adbTCPIPSucceeded(tcpipOutput) else {
            isPairing = false
            append("Could not switch to Wi-Fi. Starting USB mirror instead.")
            startMirroring()
            return
        }

        let wirelessPhone = await Self.waitForConnectableWirelessPhone(
            adb: adb,
            preferredAddress: usbWiFiAddress
        )

        guard let wirelessPhone else {
            isPairing = false
            append("Wi-Fi adb did not appear. Starting USB mirror instead.")
            startMirroring()
            return
        }

        let connectOutput = await Task.detached {
            adb.run(["connect", wirelessPhone.address])
        }.value
        append("adb connect: \(Self.oneLine(connectOutput))")

        isPairing = false
        guard Self.adbConnectSucceeded(connectOutput) else {
            append("Could not connect over Wi-Fi. Starting USB mirror instead.")
            startMirroring()
            return
        }

        finishWirelessHandoff(
            usbDevice: usbDevice,
            wirelessID: wirelessPhone.id,
            address: wirelessPhone.address
        )
    }

    private func finishWirelessHandoff(
        usbDevice: AuthorizedADBDevice,
        wirelessID: String,
        address: String
    ) {
        touchPairedPhone(
            id: wirelessID,
            displayName: usbDevice.model,
            address: address
        )
        selectedDevice.adbSerial = address
        selectedDevice.network = "Wireless debugging"
        append("Wireless mirror ready. You can unplug the cable.")
        startMirroring()
    }

    func connectViaUSB() {
        guard !isMirroring else { return }
        append("Preparing USB mirror...")
        isPairing = true

        let adb = self.adb
        Task { [weak self] in
            let output = await Task.detached { adb.run(["devices", "-l"]) }.value
            let usbDevice = Self.authorizedADBDevices(in: output).first(where: \.isUSB)
            let hasUnauthorizedUSB = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .contains { $0.contains("unauthorized") && $0.contains("usb:") }

            guard let self else { return }
            self.isPairing = false

            if hasUnauthorizedUSB {
                self.append("Phone is connected by cable, but Android has not authorized this Mac yet. Unlock the phone, accept the USB debugging prompt, then try again.")
                return
            }

            guard let usbDevice else {
                self.append("No authorized USB phone found. Plug in with a cable, accept the Android USB debugging prompt, then try again.")
                return
            }

            self.select(device: usbDevice)
            self.touchPairedPhone(
                id: usbDevice.serial,
                displayName: usbDevice.model,
                address: usbDevice.serial
            )
            self.append("USB mirror ready for \(usbDevice.model).")
            self.startMirroring()
        }
    }

    func connectWirelessly(host: String, port: String, pairingPort: String, pairingCode: String) {
        guard !isMirroring else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPairingPort = pairingPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPairingCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            append("Enter the phone IP address from Android Wireless debugging.")
            return
        }
        guard let portNumber = Int(trimmedPort), (1...65_535).contains(portNumber) else {
            append("Enter a valid wireless debugging port.")
            return
        }
        if !trimmedPairingPort.isEmpty || !trimmedPairingCode.isEmpty {
            guard let pairPortNumber = Int(trimmedPairingPort), (1...65_535).contains(pairPortNumber) else {
                append("Enter a valid pairing port, or leave pairing fields blank.")
                return
            }
            guard !trimmedPairingCode.isEmpty else {
                append("Enter the wireless pairing code shown on Android.")
                return
            }
        }

        let address = "\(trimmedHost):\(portNumber)"
        append("Connecting to wireless adb at \(address)...")
        isPairing = true

        let adb = self.adb
        Task { [weak self] in
            await adb.restartServer()
            if let pairPortNumber = Int(trimmedPairingPort), !trimmedPairingCode.isEmpty {
                let pairAddress = "\(trimmedHost):\(pairPortNumber)"
                let pairOutput = await Task.detached {
                    adb.run(["pair", pairAddress, trimmedPairingCode])
                }.value
                guard let self else { return }
                self.append("adb pair: \(Self.oneLine(pairOutput))")
                guard Self.adbPairSucceeded(pairOutput) else {
                    self.isPairing = false
                    self.append("Could not pair with \(pairAddress). Check the pairing code and pairing port.")
                    return
                }
            }

            let output = await Task.detached { adb.run(["connect", address]) }.value

            guard let self else { return }
            self.isPairing = false
            self.append("adb connect: \(Self.oneLine(output))")

            guard Self.adbConnectSucceeded(output) else {
                self.append("Could not connect to \(address). Check the IP, port, and Wireless debugging screen.")
                return
            }

            self.touchPairedPhone(
                id: address,
                displayName: "Android device",
                address: address
            )
            self.selectedDevice = MirrorDevice(
                id: address,
                name: "Android device",
                model: "Android",
                battery: self.selectedDevice.battery,
                isCharging: self.selectedDevice.isCharging,
                network: "Wireless debugging",
                lastSeen: .now,
                states: [.mirroringReady, .companionConnected],
                adbSerial: address
            )
            self.startMirroring()
        }
    }

    private func mostRecentPairedPhone(in phones: [DiscoveredPhone]) -> DiscoveredPhone? {
        for record in Self.recordsByMostRecent(pairedPhones) where Self.isWirelessRecord(record) {
            if let phone = Self.rememberedConnectablePhone(for: record, in: phones) {
                return phone
            }
        }
        return nil
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
            network: Self.isWirelessRecord(record) ? "Wireless debugging" : "USB debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: record.lastAddress
        )
    }

    nonisolated static func authorizedADBDevices(in output: String) -> [AuthorizedADBDevice] {
        output
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                guard !trimmed.isEmpty,
                      !lower.hasPrefix("list of devices"),
                      !lower.hasPrefix("* daemon")
                else {
                    return nil
                }

                let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 2,
                      fields[1] == "device",
                      let serial = fields.first
                else {
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

    nonisolated static func usbHandoffCandidate(
        in devicesOutput: String,
        lastAttemptedSerial: String?
    ) -> AuthorizedADBDevice? {
        guard let usbDevice = authorizedADBDevices(in: devicesOutput).first(where: \.isUSB),
              usbDevice.serial != lastAttemptedSerial
        else { return nil }
        return usbDevice
    }

    nonisolated static func adbConnectSucceeded(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("connected to ") || lower.contains("already connected to ")
    }

    nonisolated static func adbPairSucceeded(_ output: String) -> Bool {
        output.lowercased().contains("successfully paired")
    }

    nonisolated static func adbTCPIPSucceeded(_ output: String) -> Bool {
        output.lowercased().contains("restarting in tcp mode port:")
    }

    nonisolated static func mostRecentWirelessRecord(in records: [PairedPhoneRecord]) -> PairedPhoneRecord? {
        wirelessRecordsByMostRecent(records).first
    }

    nonisolated static func recordsByMostRecent(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records.sorted { $0.lastConnected > $1.lastConnected }
    }

    nonisolated static func wirelessRecordsByMostRecent(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records
            .filter(isWirelessRecord)
            .sorted { $0.lastConnected > $1.lastConnected }
    }

    nonisolated static func isWirelessRecord(_ record: PairedPhoneRecord) -> Bool {
        record.lastAddress.contains(":")
    }

    nonisolated static func rememberedConnectablePhone(
        for record: PairedPhoneRecord,
        in phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind == .connectable }
        if let exact = connectablePhones.first(where: { $0.id == record.id }) {
            return exact
        }
        guard let expectedHost = host(in: record.lastAddress) else {
            return connectablePhones.count == 1 ? connectablePhones.first : nil
        }
        if let sameHost = connectablePhones.first(where: { host(in: $0.address) == expectedHost }) {
            return sameHost
        }
        return connectablePhones.count == 1 ? connectablePhones.first : nil
    }

    nonisolated static func isWirelessADBTarget(_ target: String) -> Bool {
        target.contains(":") || target.contains("._adb") || target.hasPrefix("adb-")
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

    nonisolated static func wirelessDebuggingAddress(
        routeOutput: String,
        tlsPortOutput: String,
        tcpPortOutput: String? = nil
    ) -> String? {
        guard let wifiIP = wifiIPAddress(in: routeOutput) else { return nil }
        let port = validPort(in: tlsPortOutput) ?? tcpPortOutput.flatMap(validPort)
        guard let port else { return nil }
        return "\(wifiIP):\(port)"
    }

    private nonisolated static func validPort(in output: String) -> Int? {
        let trimmedPort = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmedPort), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    nonisolated static func wirelessPhoneMatchingUSBRoute(
        _ routeOutput: String,
        phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind == .connectable }
        guard let wifiIP = wifiIPAddress(in: routeOutput) else {
            return connectablePhones.first
        }
        return connectablePhones.first { host(in: $0.address) == wifiIP }
    }

    nonisolated static func connectableWirelessPhone(
        matchingHostOf address: String,
        phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind == .connectable }
        guard let expectedHost = host(in: address) else {
            return connectablePhones.first
        }
        return connectablePhones.first { host(in: $0.address) == expectedHost }
    }

    private nonisolated static func host(in address: String) -> String? {
        if address.hasPrefix("["),
           let endIndex = address.firstIndex(of: "]") {
            let hostStart = address.index(after: address.startIndex)
            return String(address[hostStart..<endIndex])
        }

        guard let separator = address.lastIndex(of: ":") else {
            return nil
        }
        return String(address[..<separator])
    }

    private static func waitForConnectableWirelessPhone(
        adb: ADBController,
        preferredAddress: String?,
        matchingHostOf address: String? = nil
    ) async -> DiscoveredPhone? {
        for _ in 0..<8 {
            if Task.isCancelled { return nil }
            if let preferredAddress {
                let connectOutput = await Task.detached { adb.run(["connect", preferredAddress]) }.value
                if Task.isCancelled { return nil }
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
            if Task.isCancelled { return nil }
            if let address {
                if let matchingPhone = connectableWirelessPhone(matchingHostOf: address, phones: phones) {
                    return matchingPhone
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
                continue
            }
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
        if let serial, Self.isWirelessADBTarget(serial) {
            startWirelessMirroring(savedTarget: serial)
            return
        }
        append(serial == nil ? "Starting native mirror..."
                              : "Starting native mirror for \(serial!)...")
        launchNativeMirror(serial: serial)
    }

    private func startWirelessMirroring(savedTarget: String) {
        guard !isPairing else { return }

        let selectedID = selectedDevice.id
        let selectedName = selectedDevice.name
        let adb = self.adb

        isPairing = true
        append("Checking wireless route for \(savedTarget)...")

        Task { [weak self] in
            var target: String?

            if savedTarget.contains(":") {
                let connectOutput = await Task.detached {
                    adb.run(["connect", savedTarget])
                }.value

                guard let self else { return }
                self.append("adb connect: \(Self.oneLine(connectOutput))")
                if Self.adbConnectSucceeded(connectOutput) {
                    target = savedTarget
                }
            }

            guard let self else { return }
            if target == nil {
                let livePhones = await Task.detached {
                    adb.connectableMDNSTargets()
                }.value
                let phones = livePhones + self.discoveredPhones
                let record = Self.recordsByMostRecent(self.pairedPhones).first { record in
                    record.id == selectedID || record.lastAddress == savedTarget
                }
                let refreshedPhone = record.flatMap {
                    Self.rememberedConnectablePhone(for: $0, in: phones)
                } ?? (phones.filter { $0.kind == .connectable }.count == 1
                    ? phones.first(where: { $0.kind == .connectable })
                    : nil)

                if let refreshedPhone {
                    self.append("Wireless route changed. Trying \(refreshedPhone.address)...")
                    let connectOutput = await Task.detached {
                        adb.run(["connect", refreshedPhone.address])
                    }.value
                    self.append("adb connect: \(Self.oneLine(connectOutput))")
                    if Self.adbConnectSucceeded(connectOutput) {
                        target = refreshedPhone.address
                        self.touchPairedPhone(
                            id: refreshedPhone.id,
                            displayName: record?.displayName ?? selectedName,
                            address: refreshedPhone.address
                        )
                    }
                }
            }

            self.isPairing = false
            guard let target else {
                self.append("Could not connect over Wi-Fi. Open Android Wireless debugging and pair or refresh the route.")
                return
            }
            self.selectedDevice.adbSerial = target
            self.launchNativeMirror(serial: target)
        }
    }

    func stopMirroring() {
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        isMirroring = false
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
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
            if self.isRecording {
                self.isRecording = false
                self.stopScreenRecordingCleanup()
            }
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

    private func hideConnectionWindowForNativeMirror() {
        connectionWindow?.close()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentCaptureCue(_ kind: CaptureCueKind) {
        captureCue = CaptureCue(kind: kind)
        if NSSound(named: NSSound.Name("Grab"))?.play() == true {
            return
        }
        if NSSound(named: NSSound.Name("Pop"))?.play() == true {
            return
        }
        NSSound.beep()
    }

    // MARK: - Resize

    func resizeMirror(scale: CGFloat) {
        mirrorSession?.scaleWindow(by: scale)
    }

    func centerMirrorWindow() {
        mirrorSession?.centerWindow()
    }

    func forgetPairedPhone(id: PairedPhoneRecord.ID) {
        pairedPhones = store.removing(id, from: pairedPhones)
        store.save(pairedPhones)
        if selectedDevice.id == id {
            selectedDevice = .demo
        }
        append("Forgot paired device.")
    }

    func forgetAllPairedPhones() {
        pairedPhones = []
        store.clearAll()
        selectedDevice = .demo
        append("Forgot all paired devices. Reconnect from scratch to mirror again.")
    }

    // MARK: - Android input

    func sendAndroidKey(_ keycode: String) {
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        Task.detached {
            var arguments: [String] = []
            if let serial, !serial.isEmpty {
                arguments.append(contentsOf: ["-s", serial])
            }
            arguments.append(contentsOf: ["shell", "input", "keyevent", keycode])
            adb.run(arguments)
        }
    }

    func takeScreenshot() {
        let serial = selectedDevice.adbSerial
        presentCaptureCue(.screenshot)
        append("Saving screenshot to Downloads/Android Mirroring...")
        Task { [weak self] in
            let result = await Task.detached { () -> Result<URL, ScreenshotError> in
                guard let adbPath = Tooling.toolPath(named: "adb") else {
                    return .failure(.adbMissing)
                }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = Self.adbDeviceArguments(serial: serial)
                    + ["exec-out", "screencap", "-p"]
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard !data.isEmpty else {
                        return .failure(.emptyOutput)
                    }
                    let directory = try Self.mediaOutputDirectory()
                    let url = directory.appendingPathComponent(Self.mediaFilename(
                        prefix: "Android Mirroring Screenshot",
                        extension: "png"
                    ))
                    try data.write(to: url)
                    return .success(url)
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            guard let self else { return }
            switch result {
            case .success(let url):
                self.append("Saved screenshot: \(url.lastPathComponent)")
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
            startScreenRecording()
        }
    }

    private func startScreenRecording() {
        isRecording = true
        presentCaptureCue(.recordingStarted)
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        Task { [weak self] in
            let alreadyRunning = await Task.detached {
                Self.androidScreenRecordingIsRunning(adb: adb, serial: serial)
            }.value

            guard let self else { return }
            if alreadyRunning {
                self.append("Android screen recording is already active. Click again to stop and save it.")
                self.startScreenRecordingMonitor()
                return
            }

            let output = await Task.detached {
                adb.run(Self.adbDeviceArguments(serial: serial) + [
                    "shell",
                    "rm -f /sdcard/android-mirroring-record.mp4; screenrecord /sdcard/android-mirroring-record.mp4 >/dev/null 2>&1 & echo started"
                ])
            }.value

            guard output.lowercased().contains("started") else {
                self.isRecording = false
                self.append("Could not start Android screen recording.")
                return
            }

            self.isRecording = true
            self.append("Started Android screen recording.")
            self.startScreenRecordingMonitor()
        }
    }

    private func stopScreenRecordingCleanup() {
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
        append("Stopping Android screen recording...")
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        Task { [weak self] in
            await Task.detached {
                _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                    "shell",
                    "pkill -2 screenrecord >/dev/null 2>&1"
                ])
            }.value
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let result = await Task.detached { () -> Result<URL, RecordingError> in
                do {
                    let directory = try Self.mediaOutputDirectory()
                    let url = directory.appendingPathComponent(Self.mediaFilename(
                        prefix: "Android Mirroring Screen Recording",
                        extension: "mp4"
                    ))
                    let output = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "pull", "/sdcard/android-mirroring-record.mp4",
                        url.path
                    ], timeout: 120)
                    _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "shell",
                        "rm -f /sdcard/android-mirroring-record.mp4 >/dev/null 2>&1"
                    ])
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return .failure(.pullFailed(Self.oneLine(output)))
                    }
                    return .success(url)
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            switch result {
            case .success(let url):
                self?.presentCaptureCue(.recordingStopped)
                self?.append("Saved screen recording: \(url.lastPathComponent)")
            case .failure(.pullFailed(let message)):
                self?.append("Screen recording save failed: \(message)")
            case .failure(.runtime(let message)):
                self?.append("Screen recording save failed: \(message)")
            }
        }
    }

    private func startScreenRecordingMonitor() {
        screenRecordingMonitorTask?.cancel()
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        screenRecordingMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                let running = await Task.detached {
                    Self.androidScreenRecordingIsRunning(adb: adb, serial: serial)
                }.value
                guard let self else { return }
                if self.isRecording && !running {
                    self.isRecording = false
                    self.screenRecordingMonitorTask = nil
                    self.append("Android screen recording ended. Saving the recording...")
                    self.stopScreenRecordingCleanup()
                    return
                }
            }
        }
    }

    nonisolated private static func androidScreenRecordingIsRunning(adb: ADBController, serial: String?) -> Bool {
        let output = adb.run(Self.adbDeviceArguments(serial: serial) + [
            "shell",
            "if pgrep -x screenrecord >/dev/null 2>&1; then echo running; else echo stopped; fi"
        ])
        return output.lowercased().contains("running")
    }

    private enum RecordingError: Error {
        case pullFailed(String)
        case runtime(String)
    }

    nonisolated private static func adbDeviceArguments(serial: String?) -> [String] {
        guard let serial, !serial.isEmpty else { return [] }
        return ["-s", serial]
    }

    nonisolated private static func mediaOutputDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Android Mirroring", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func mediaFilename(prefix: String, extension fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(fileExtension)"
    }

    // MARK: - Diagnostics

    private func append(_ message: String) {
        Logger.log("Diagnostic: \(message)")
        diagnostics.insert(DiagnosticLine(date: .now, message: message), at: 0)
        diagnostics = Array(diagnostics.prefix(8))
    }

    nonisolated static func oneLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
