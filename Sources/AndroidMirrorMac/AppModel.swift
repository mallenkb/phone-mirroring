import SwiftUI
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedDevice: MirrorDevice = .demo
    @Published var isScanning = false
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var isPairing = false
    @Published private(set) var isSelectedDeviceOnline = false
    @Published var captureCue: CaptureCue?
    /// Stream the phone's audio to the Mac. Off by default: it requires Android
    /// playback capture, which some device servers (e.g. Samsung One UI) abort
    /// on — and that abort also destabilizes the video stream. Opt-in via the
    /// menu; persisted across launches.
    @Published var mirrorPhoneAudio: Bool = UserDefaults.standard.bool(forKey: "AndroidMirror.MirrorPhoneAudio") {
        didSet { UserDefaults.standard.set(mirrorPhoneAudio, forKey: "AndroidMirror.MirrorPhoneAudio") }
    }
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
    private var devicePresenceTask: Task<Void, Never>?
    private var usbHandoffTask: Task<Void, Never>?
    private var lastUSBHandoffSerial: String?
    private var qrPairingTask: Task<Void, Never>?
    private var screenRecordingMonitorTask: Task<Void, Never>?
    /// Holds the currently-playing capture cue sound so it isn't deallocated
    /// mid-playback.
    private var retainedCaptureSound: NSSound?
    // Crash-loop breaker + audio fallback for flaky device-side servers.
    private var lastMirrorStartAt: Date?
    private var consecutiveQuickMirrorFailures = 0
    private var autoMirrorBackoffUntil: Date?
    /// Set once a device-side server crashes on the audio socket. Kept for the
    /// rest of the run (wireless serials change between reconnects, so a
    /// per-serial set misses) so we don't re-attempt audio and re-flash. A
    /// manual Start clears it to re-test audio.
    private var audioCaptureUnsupported = false
    /// True while a mirror session has ended but we're about to retry/reconnect
    /// (e.g. audio→video fallback, or within the backoff window). Keeps the app
    /// from terminating in the windowless gap between sessions.
    private(set) var isAwaitingReconnect = false
    /// A session that dies sooner than this counts as a "quick" failure.
    static let quickMirrorFailureThreshold: TimeInterval = 12

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
        startDevicePresenceWatcher()
        startUSBHandoffWatcher()
        attemptAutoReconnect()
    }

    deinit {
        devicePresenceTask?.cancel()
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

        let adb = self.adb
        Task { [weak self] in
            await adb.restartServer()
            let output = await Task.detached { adb.run(["connect", address]) }.value

            guard let self else { return }
            let lower = output.lowercased()
            let ok = lower.contains("connected") || lower.contains("already")
            if ok {
                self.touchPairedPhone(id: serviceID, displayName: label, address: address)
                self.selectedDevice.adbSerial = address
                self.stopQRCodePairingSession()
                self.startMirroring()
            } else {
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
                await self.prepareWirelessMirror(from: usbDevice)
            }
        }
    }

    private func startDevicePresenceWatcher() {
        guard devicePresenceTask == nil else { return }
        let adb = self.adb
        devicePresenceTask = Task { [weak self] in
            while !Task.isCancelled {
                let output = await Task.detached { adb.run(["devices", "-l"]) }.value
                guard let self else { return }
                self.applyDevicePresence(output)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
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

                let pairOutput = await Task.detached {
                    adb.run(["pair", pairingPhone.address, session.password])
                }.value
                guard !Task.isCancelled else { return }

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
        startMirroring()
    }

    private func prepareWirelessMirror(from usbDevice: AuthorizedADBDevice) async {
        select(device: usbDevice)
        touchPairedPhone(
            id: usbDevice.serial,
            displayName: usbDevice.model,
            address: usbDevice.serial
        )

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
            let connectOutput = await Task.detached {
                adb.run(["connect", tlsAddress])
            }.value

            if Self.adbConnectSucceeded(connectOutput) {
                isPairing = false
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    wirelessID: tlsAddress,
                    address: tlsAddress
                )
                return
            }

        }

        let discoveredWirelessPhones = await Task.detached {
            adb.connectableMDNSTargets()
        }.value
        if let wirelessPhone = Self.wirelessPhoneMatchingUSBRoute(
            routeOutput,
            phones: discoveredWirelessPhones
        ) {
            let connectOutput = await Task.detached {
                adb.run(["connect", wirelessPhone.address])
            }.value

            if Self.adbConnectSucceeded(connectOutput) {
                isPairing = false
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    wirelessID: wirelessPhone.id,
                    address: wirelessPhone.address
                )
                return
            }

        }

        isPairing = false
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
        startMirroring()
    }

    func connectViaUSB() {
        guard !isMirroring else { return }
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
                return
            }

            guard let usbDevice else {
                return
            }

            self.select(device: usbDevice)
            self.touchPairedPhone(
                id: usbDevice.serial,
                displayName: usbDevice.model,
                address: usbDevice.serial
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
            isSelectedDeviceOnline = false
            return
        }

        select(device: first)
    }

    private func select(device: AuthorizedADBDevice) {
        isSelectedDeviceOnline = true
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
        isSelectedDeviceOnline = false
        selectedDevice = MirrorDevice(
            id: record.id,
            name: record.displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: Self.isWirelessRecord(record) ? "Wireless debugging" : "USB debugging",
            lastSeen: record.lastConnected,
            states: [.wirelessDebuggingRequired, .companionConnected],
            adbSerial: record.lastAddress
        )
    }

    private func applyDevicePresence(_ output: String) {
        let devices = Self.authorizedADBDevices(in: output)
        guard let serial = selectedDevice.adbSerial else {
            isSelectedDeviceOnline = false
            return
        }

        guard let liveDevice = devices.first(where: { $0.serial == serial }) else {
            isSelectedDeviceOnline = false
            if selectedDevice.states.contains(.mirroringReady) {
                selectedDevice.states = [.wirelessDebuggingRequired, .companionConnected]
            }
            return
        }

        isSelectedDeviceOnline = true
        selectedDevice.lastSeen = .now
        selectedDevice.name = liveDevice.model
        selectedDevice.model = liveDevice.product
        selectedDevice.network = liveDevice.isUSB ? "USB debugging" : "Wireless debugging"
        selectedDevice.states = [.mirroringReady, .companionConnected]
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

    nonisolated static func recordsByMostRecent(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records.sorted { $0.lastConnected > $1.lastConnected }
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

    /// - Parameter manual: `true` for a deliberate user action, which clears
    ///   any crash-loop backoff and re-enables audio. Auto-reconnect callers
    ///   leave it `false` so a crashing server isn't relaunched in a tight loop.
    func startMirroring(manual: Bool = false) {
        guard !isMirroring else { return }

        if manual {
            // A deliberate retry clears backoff and re-tests audio support.
            consecutiveQuickMirrorFailures = 0
            autoMirrorBackoffUntil = nil
            audioCaptureUnsupported = false
        } else if let until = autoMirrorBackoffUntil, Date() < until {
            return
        }

        let serial = selectedDevice.adbSerial
        if let serial, Self.isWirelessADBTarget(serial) {
            startWirelessMirroring(savedTarget: serial)
            return
        }
        launchNativeMirror(serial: serial)
    }

    private func startWirelessMirroring(savedTarget: String) {
        guard !isPairing else { return }

        let selectedID = selectedDevice.id
        let selectedName = selectedDevice.name
        let adb = self.adb

        isPairing = true

        Task { [weak self] in
            var target: String?

            if savedTarget.contains(":") {
                let connectOutput = await Task.detached {
                    adb.run(["connect", savedTarget])
                }.value

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
                    let connectOutput = await Task.detached {
                        adb.run(["connect", refreshedPhone.address])
                    }.value
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
        // A deliberate stop clears the crash-loop breaker. (Learned audio
        // support is kept so auto-reconnect doesn't re-flash on a device that
        // can't capture audio; a manual Start re-tests it.)
        consecutiveQuickMirrorFailures = 0
        autoMirrorBackoffUntil = nil
        isAwaitingReconnect = false
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
    }

    /// Toggle phone-audio passthrough. Applied immediately by restarting a live
    /// session (audio is negotiated at session start).
    func setMirrorPhoneAudio(_ enabled: Bool) {
        guard enabled != mirrorPhoneAudio else { return }
        mirrorPhoneAudio = enabled
        guard isMirroring else { return }
        stopMirroring()
        startMirroring(manual: true)
    }

    private func launchNativeMirror(serial: String?) {
        let session = MirrorSession(model: self, serial: serial, audioEnabled: mirrorPhoneAudio && !audioCaptureUnsupported)
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
            self.noteMirrorSessionEnded(audioWasEnabled: session?.audioEnabled ?? false)
        }

        do {
            mirrorSession = session
            isMirroring = true
            isAwaitingReconnect = false
            selectedDevice.states = [.mirroringReady, .companionConnected]
            lastMirrorStartAt = Date()
            try session.start()
            hideConnectionWindowForNativeMirror()
        } catch {
            session.onSessionEnded = nil
            session.stop()
            if mirrorSession === session {
                mirrorSession = nil
            }
            isMirroring = false
        }
    }

    /// Called when a native mirror session ends. Distinguishes a stable session
    /// (resets all breakers) from a "quick" failure. On a quick failure with
    /// audio on, we retry once with audio off (some device servers can't
    /// capture audio cleanly); otherwise we arm a growing reconnect backoff.
    private func noteMirrorSessionEnded(audioWasEnabled: Bool) {
        let lived = lastMirrorStartAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard lived < Self.quickMirrorFailureThreshold else {
            // Stable session — reset the reconnect backoff. (Keep learned audio
            // support; a stable video-only session doesn't mean audio works.)
            consecutiveQuickMirrorFailures = 0
            autoMirrorBackoffUntil = nil
            return
        }

        // A quick failure while audio was on usually means the device server
        // can't capture audio — remember that and retry once, video only.
        if audioWasEnabled, !audioCaptureUnsupported {
            audioCaptureUnsupported = true
            isAwaitingReconnect = true
            Logger.log("Mirror exited quickly with audio on — this device can't capture audio; retrying video only.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.startMirroring()
            }
            return
        }

        consecutiveQuickMirrorFailures += 1
        let backoff = Self.mirrorBackoffInterval(forFailureCount: consecutiveQuickMirrorFailures)
        guard backoff > 0 else { return }
        autoMirrorBackoffUntil = Date().addingTimeInterval(backoff)
        isAwaitingReconnect = true
        Logger.log("Mirror keeps disconnecting right after it starts. Pausing auto-reconnect for \(Int(backoff))s.")
    }

    /// Backoff schedule keyed on consecutive quick failures. The first failure
    /// is free (transient drops happen); repeats grow up to a 30s ceiling.
    nonisolated static func mirrorBackoffInterval(forFailureCount count: Int) -> TimeInterval {
        switch count {
        case ..<2: return 0
        case 2: return 10
        case 3: return 20
        default: return 30
        }
    }

    private func hideConnectionWindowForNativeMirror() {
        connectionWindow?.close()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentCaptureCue(_ kind: CaptureCueKind) {
        captureCue = CaptureCue(kind: kind)
        playCaptureSound(for: kind)
    }

    /// Plays a distinct cue per capture action. Screenshots use the real macOS
    /// shutter sound; recording start/stop use the system screen-capture cue.
    /// These ship inside CoreAudio.component (not in `NSSound(named:)`'s search
    /// path), so we load them by file path, then fall back to named system
    /// sounds, then a beep. `retainedCaptureSound` keeps the player alive until
    /// playback finishes (a local NSSound would be deallocated immediately).
    private func playCaptureSound(for kind: CaptureCueKind) {
        let fileCandidates: [String]
        let namedFallbacks: [String]
        switch kind {
        case .screenshot:
            fileCandidates = ["Grab.aif", "Shutter.aif"]   // real screenshot shutter
            namedFallbacks = ["Tink", "Pop"]
        case .recordingStarted:
            fileCandidates = ["Screen Capture.aif"]         // "begin" cue
            namedFallbacks = ["Bottle", "Pop"]
        case .recordingStopped:
            fileCandidates = ["Screen Capture.aif"]         // "saved/done" cue
            namedFallbacks = ["Glass", "Submarine"]
        }

        for file in fileCandidates {
            let path = Self.systemSoundsDirectory + file
            if let sound = NSSound(contentsOfFile: path, byReference: true), sound.play() {
                retainedCaptureSound = sound
                return
            }
        }
        for name in namedFallbacks {
            if let sound = NSSound(named: NSSound.Name(name)), sound.play() {
                retainedCaptureSound = sound
                return
            }
        }
        NSSound.beep()
    }

    private static let systemSoundsDirectory =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"

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
    }

    func forgetAllPairedPhones() {
        pairedPhones = []
        store.clearAll()
        selectedDevice = .demo
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
        Task {
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
                        kind: "Screenshot",
                        extension: "png"
                    ))
                    try data.write(to: url)
                    return .success(url)
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            switch result {
            case .success(let url):
                Logger.log("Saved screenshot: \(url.path)")
            case .failure(.adbMissing):
                Logger.log("Screenshot failed: adb is missing")
            case .failure(.emptyOutput):
                Logger.log("Screenshot failed: empty screencap output")
            case .failure(.runtime(let message)):
                Logger.log("Screenshot failed: \(message)")
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
                return
            }

            self.isRecording = true
            self.startScreenRecordingMonitor()
        }
    }

    private func stopScreenRecordingCleanup() {
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
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
                        kind: "Screen-Recording",
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
                Logger.log("Saved screen recording: \(url.path)")
                self?.presentCaptureCue(.recordingStopped)
            case .failure(.pullFailed(let message)):
                Logger.log("Screen recording pull failed: \(message)")
            case .failure(.runtime(let message)):
                Logger.log("Screen recording save failed: \(message)")
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
            .appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func mediaFilename(kind: String, extension fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Android-Mirroring-\(kind)_\(formatter.string(from: Date())).\(fileExtension)"
    }

    nonisolated static func oneLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
