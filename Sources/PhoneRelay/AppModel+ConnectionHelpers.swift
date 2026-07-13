import AppKit
import Foundation
import Network

// Pure move from AppModel.swift (2026-07-05): the stateless connection
// toolbox — adb output parsing, wireless address/readiness probing, handoff
// budgets, record matching, and device naming. Everything here is static;
// the ordering/timeout choices encode INVARIANTS.md rules 2, 3, 5 and 9 —
// read those before "simplifying".
extension AppModel {

    nonisolated static func adbConnectSucceeded(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("connected to ") || lower.contains("already connected to ")
    }

    /// Not private: still called from AppModel.swift (pure-move split);
    /// treat as private elsewhere.
    nonisolated static func port(in address: String) -> Int? {
        if address.hasPrefix("[") {
            guard let bracket = address.firstIndex(of: "]"),
                  address.index(after: bracket) < address.endIndex,
                  address[address.index(after: bracket)] == ":"
            else { return nil }
            let portStart = address.index(bracket, offsetBy: 2)
            return Int(address[portStart...])
        }
        guard let separator = address.lastIndex(of: ":"),
              address[..<separator].contains(":") == false
        else { return nil }
        return Int(address[address.index(after: separator)...])
    }

    /// Wireless addresses to try for a remembered phone, most-preferred first.
    /// Always includes the stable legacy `:5555` port: an older record may have
    /// saved a random Wireless-debugging TLS port that no longer answers once
    /// the toggle is off, whereas a `tcpip` listener on 5555 survives without it.
    nonisolated static func reconnectCandidateAddresses(for savedAddress: String) -> [String] {
        var candidates = [savedAddress]
        if let host = host(in: savedAddress) {
            let legacy = "\(host):\(legacyADBWirelessPort)"
            if !candidates.contains(legacy) {
                candidates.append(legacy)
            }
        }
        return candidates
    }

    /// Canonical reconnect order for one phone. Stable legacy listeners are
    /// always preferred to random TLS ports, including when mDNS advertises a
    /// fresh TLS endpoint. Reachability may move live endpoints ahead of dead
    /// ones later, but never changes preference within the live group.
    nonisolated static func canonicalReconnectCandidateAddresses(
        savedAddress: String,
        liveAddress: String?
    ) -> [String] {
        var candidates: [String] = []

        func append(_ address: String?) {
            guard let address, !address.isEmpty, !candidates.contains(address) else { return }
            candidates.append(address)
        }

        // Prefer :5555 on the remembered host, followed by :5555 on a newly
        // discovered host after DHCP movement.
        if let savedHost = host(in: savedAddress) {
            append("\(savedHost):\(legacyADBWirelessPort)")
        }
        if let liveAddress, let liveHost = host(in: liveAddress) {
            append("\(liveHost):\(legacyADBWirelessPort)")
        }

        if port(in: savedAddress) != legacyADBWirelessPort {
            append(savedAddress)
        }
        if let liveAddress, port(in: liveAddress) != legacyADBWirelessPort {
            append(liveAddress)
        }

        // Service-name targets may not expose a host that can be rewritten.
        if candidates.isEmpty {
            append(savedAddress)
            append(liveAddress)
        }
        return candidates
    }

    /// Persistence choke point for wireless routes. A successful session may
    /// be identified by a USB serial or service name, but only a concrete
    /// host:port endpoint may replace the remembered Wi-Fi address.
    nonisolated static func persistableWirelessAddress(_ address: String?) -> String? {
        guard let address,
              localNetworkEndpointParts(from: address) != nil else { return nil }
        return address
    }

    /// Chooses what, if anything, may replace the stored Wi-Fi route after a
    /// verified session. A promoted/stable listener wins; a temporary TLS port
    /// is stored only when there is no existing stable fallback.
    nonisolated static func automaticWirelessAddressToPersist(
        sessionAddress: String,
        existingWirelessAddress: String?
    ) -> String? {
        let session = persistableWirelessAddress(sessionAddress)
        let existingStable = persistableWirelessAddress(existingWirelessAddress).flatMap {
            port(in: $0) == legacyADBWirelessPort ? $0 : nil
        }
        if let session, port(in: session) == legacyADBWirelessPort {
            return session
        }
        if existingStable != nil {
            return nil
        }
        return session
    }

    /// Stable partition of reconnect candidates: hosts whose port answered a
    /// probe first, everything else after, preserving the preference order
    /// within each group. Returns the input unchanged when the probe result
    /// carries no signal (nothing reachable, or everything reachable), so the
    /// savedAddress-before-legacy-5555 preference is never disturbed.
    nonisolated static func orderedByReachability(
        _ candidates: [String],
        reachable: Set<String>
    ) -> [String] {
        guard !reachable.isEmpty, reachable.count < candidates.count else { return candidates }
        return candidates.filter(reachable.contains)
            + candidates.filter { !reachable.contains($0) }
    }

    /// Tries each candidate address for a remembered phone and returns the first
    /// one that's actually usable, or nil. Needs no phone interaction and no
    /// Wireless debugging toggle — just reachability on the current network.
    ///
    /// A bare `adb connect` is not enough: adb happily reports "already connected
    /// to <host>" for a stale entry whose phone is asleep or off the network, and
    /// launching a mirror against it then fails. So every candidate must also pass
    /// a `shell echo` readiness probe before we treat it as connected.
    /// Outcome of dialing a remembered wireless route across its candidate
    /// addresses. Carries the aggregated readiness signal so callers can tell a
    /// macOS Local Network denial (every connect failed "No route to host")
    /// apart from a phone that is simply offline — and surface the right hint.
    struct RememberedWirelessConnectResult {
        var connectedAddress: String?
        var connectAttempts: Int
        var noRouteToHostFailures: Int
        /// Aggregated attribution signature — see `WirelessTargetReadiness`.
        var sawReachableNoRoute: Bool = false

        var sawNoRouteToHost: Bool {
            connectAttempts > 0 && connectAttempts == noRouteToHostFailures
        }
    }

    nonisolated static func connectToRememberedWirelessReadiness(
        adb: ADBController,
        savedAddress: String,
        candidateAddresses: [String]? = nil,
        readinessAttempts: Int = 1,
        delayNanoseconds: UInt64 = 700_000_000,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        maximumDuration: TimeInterval? = nil,
        connectTimeout: TimeInterval = 5,
        shellTimeout: TimeInterval = 2
    ) async -> RememberedWirelessConnectResult {
        let startedAt = Date()
        func remainingBudget() -> TimeInterval? {
            guard let maximumDuration else { return nil }
            return max(0, maximumDuration - Date().timeIntervalSince(startedAt))
        }

        var connectAttempts = 0
        var noRouteToHostFailures = 0
        var sawReachableNoRoute = false
        var candidates = candidateAddresses ?? reconnectCandidateAddresses(for: savedAddress)
        if candidates.count > 1 {
            // One concurrent TCP probe round (~0.45s) so the candidate that is
            // actually alive gets dialed first — otherwise a stale saved
            // Wireless-debugging port costs a full serialized `adb connect`
            // timeout before the live `:5555` fallback ever gets its turn.
            // Preference order within alive/dead groups is preserved, so a
            // live saved address still beats the legacy fallback.
            var reachable: Set<String> = []
            await withTaskGroup(of: (String, Bool).self) { group in
                for candidate in candidates {
                    group.addTask { (candidate, await adbTCPPortProbe(candidate)) }
                }
                for await (candidate, isOpen) in group where isOpen {
                    reachable.insert(candidate)
                }
            }
            let reachableCandidates = candidates.filter(reachable.contains)
            let preferredStable = candidates.first {
                port(in: $0) == legacyADBWirelessPort
            }
            var dialCandidates = reachableCandidates
            // A plain :5555 phone may reject a short probe while waking. After
            // all demonstrably-live routes, give only the preferred stable
            // endpoint one real adb connect attempt; do not dial every dead TLS
            // address and create stale duplicate transports.
            if let preferredStable, !dialCandidates.contains(preferredStable) {
                dialCandidates.append(preferredStable)
            }
            if dialCandidates.isEmpty, let first = candidates.first {
                dialCandidates.append(first)
            }
            candidates = dialCandidates
        }
        for candidate in candidates {
            let readiness = await waitForADBWirelessTargetReadiness(
                adb: adb,
                address: candidate,
                attempts: readinessAttempts,
                delayNanoseconds: delayNanoseconds,
                preflightLocalNetworkAccess: preflightLocalNetworkAccess,
                tcpPortProbe: { address in
                    await adbTCPPortProbe(address)
                },
                maximumDuration: remainingBudget(),
                connectTimeout: connectTimeout,
                shellTimeout: shellTimeout
            )
            connectAttempts += readiness.connectAttempts
            noRouteToHostFailures += readiness.noRouteToHostFailures
            sawReachableNoRoute = sawReachableNoRoute || readiness.sawReachableNoRoute
            if readiness.isReady {
                return RememberedWirelessConnectResult(
                    connectedAddress: candidate,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures,
                    sawReachableNoRoute: sawReachableNoRoute
                )
            }
        }
        return RememberedWirelessConnectResult(
            connectedAddress: nil,
            connectAttempts: connectAttempts,
            noRouteToHostFailures: noRouteToHostFailures,
            sawReachableNoRoute: sawReachableNoRoute
        )
    }

    nonisolated static func connectToRememberedWireless(
        adb: ADBController,
        savedAddress: String,
        readinessAttempts: Int = 1,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil
    ) async -> String? {
        await connectToRememberedWirelessReadiness(
            adb: adb,
            savedAddress: savedAddress,
            readinessAttempts: readinessAttempts,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess
        ).connectedAddress
    }

    nonisolated static func connectToUSBDeviceOverCurrentWiFi(
        adb: ADBController,
        usbDevice: AuthorizedADBDevice,
        readinessAttempts: Int = 1,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        maximumDuration: TimeInterval? = wirelessHandoffMaxDuration
    ) async -> String? {
        let handoffStartedAt = Date()
        func remainingBudget() -> TimeInterval? {
            guard let maximumDuration else { return nil }
            return max(0, maximumDuration - Date().timeIntervalSince(handoffStartedAt))
        }
        func boundedTimeout(_ requested: TimeInterval) -> TimeInterval? {
            guard let remaining = remainingBudget() else { return requested }
            guard remaining > 0.05 else { return nil }
            return min(requested, remaining)
        }
        guard let routeQueryTimeout = boundedTimeout(wirelessHandoffRouteQueryTimeout) else {
            return nil
        }
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"], timeout: routeQueryTimeout)
        }.value
        guard let wirelessAddress = legacyTCPIPDebuggingAddress(routeOutput: routeOutput) else {
            return nil
        }

        if let primeTimeout = boundedTimeout(wirelessHandoffRoutePrimeTimeout) {
            await primeADBWirelessRoute(
                adb: adb,
                usbSerial: usbDevice.serial,
                wirelessAddress: wirelessAddress,
                timeout: primeTimeout
            )
        }

        if await waitForADBWirelessTargetReady(
            adb: adb,
            address: wirelessAddress,
            attempts: readinessAttempts,
            delayNanoseconds: wirelessHandoffRetryDelayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            primeRoute: {
                let timeout = min(wirelessHandoffRoutePrimeTimeout, remainingBudget() ?? wirelessHandoffRoutePrimeTimeout)
                guard timeout > 0.05 else { return }
                await primeADBWirelessRoute(
                    adb: adb,
                    usbSerial: usbDevice.serial,
                    wirelessAddress: wirelessAddress,
                    timeout: timeout
                )
            },
            tcpPortProbe: { address in
                await adbTCPPortProbe(address)
            },
            maximumDuration: remainingBudget(),
            connectTimeout: wirelessHandoffConnectTimeout,
            shellTimeout: wirelessHandoffShellTimeout
        ) {
            return wirelessAddress
        }

        guard let tcpipTimeout = boundedTimeout(wirelessHandoffTCPIPTimeout) else {
            return nil
        }
        let tcpipOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "tcpip", "\(legacyADBWirelessPort)"], timeout: tcpipTimeout)
        }.value
        guard adbTCPIPSucceeded(tcpipOutput) else { return nil }

        return await waitForADBWirelessTargetReady(
            adb: adb,
            address: wirelessAddress,
            attempts: readinessAttempts,
            delayNanoseconds: wirelessHandoffRetryDelayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            primeRoute: {
                let timeout = min(wirelessHandoffRoutePrimeTimeout, remainingBudget() ?? wirelessHandoffRoutePrimeTimeout)
                guard timeout > 0.05 else { return }
                await primeADBWirelessRoute(
                    adb: adb,
                    usbSerial: usbDevice.serial,
                    wirelessAddress: wirelessAddress,
                    timeout: timeout
                )
            },
            tcpPortProbe: { address in
                await adbTCPPortProbe(address)
            },
            maximumDuration: remainingBudget(),
            connectTimeout: wirelessHandoffConnectTimeout,
            shellTimeout: wirelessHandoffShellTimeout
        ) ? wirelessAddress : nil
    }

    /// Whether a freshly-connected wireless target is worth promoting to a plain
    /// `tcpip 5555` listener. Anything already on 5555 is left alone.
    nonisolated static func shouldPromoteToLegacyTCPIP(connectedAddress: String) -> Bool {
        !connectedAddress.hasSuffix(":\(legacyADBWirelessPort)")
    }

    /// Outcome of a legacy `tcpip 5555` promotion. The distinction matters
    /// because `adb tcpip` restarts the phone's adbd: once it has run, the
    /// caller's original transport is gone whether or not `host:5555` came up.
    enum LegacyTCPIPPromotion: Equatable {
        /// The phone now listens on `host:5555`, verified adb-ready.
        case promoted(String)
        /// Promotion never restarted adbd (no Wi-Fi route, tcpip refused, or
        /// already on 5555 handled by the caller) — the original transport is
        /// untouched and safe to keep using.
        case unavailable
        /// `adb tcpip` restarted adbd but `host:5555` never came ready within
        /// budget. The original transport died with the restart — the caller
        /// must not mirror against it. Carries the legacy address where the
        /// phone will appear once adbd finishes coming up.
        case transportLost(legacyAddress: String)
    }

    /// Promotes an already-connected wireless adb device (e.g. one reached via
    /// Android 11 Wireless debugging on a random TLS port) to a plain `tcpip
    /// 5555` listener, so later reconnects work on the same Wi-Fi without the
    /// Wireless-debugging toggle. `adb tcpip` works over any transport, so the
    /// source can itself be a wireless address — no USB cable required.
    nonisolated static func promoteToLegacyTCPIP(
        adb: ADBController,
        sourceSerial: String,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil
    ) async -> LegacyTCPIPPromotion {
        let handoffStartedAt = Date()
        func remainingBudget() -> TimeInterval {
            remainingWirelessHandoffBudget(startedAt: handoffStartedAt)
        }
        guard remainingBudget() > 0.05 else { return .unavailable }
        let routeOutput = await Task.detached {
            adb.run(
                ["-s", sourceSerial, "shell", "ip", "route"],
                timeout: min(wirelessHandoffRouteQueryTimeout, remainingBudget())
            )
        }.value
        guard let legacyAddress = legacyTCPIPDebuggingAddress(routeOutput: routeOutput) else {
            return .unavailable
        }
        if legacyAddress == sourceSerial {
            return .promoted(legacyAddress)
        }

        guard remainingBudget() > 0.05 else { return .unavailable }
        let tcpipOutput = await Task.detached {
            adb.run(
                ["-s", sourceSerial, "tcpip", "\(legacyADBWirelessPort)"],
                timeout: min(wirelessHandoffTCPIPTimeout, remainingBudget())
            )
        }.value
        guard adbTCPIPSucceeded(tcpipOutput) else { return .unavailable }

        // adbd restarts on 5555; the old transport drops, so retry connect.
        let ready = await waitForADBWirelessTargetReady(
            adb: adb,
            address: legacyAddress,
            attempts: wirelessHandoffReadinessAttempts,
            delayNanoseconds: wirelessHandoffRetryDelayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            tcpPortProbe: { address in
                await adbTCPPortProbe(address)
            },
            maximumDuration: remainingBudget(),
            connectTimeout: wirelessHandoffConnectTimeout,
            shellTimeout: wirelessHandoffShellTimeout
        )
        return ready ? .promoted(legacyAddress) : .transportLost(legacyAddress: legacyAddress)
    }

    nonisolated static func adbPairSucceeded(_ output: String) -> Bool {
        output.lowercased().contains("successfully paired")
    }

    nonisolated static func recordsByMostRecent(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records.sorted { $0.lastConnected > $1.lastConnected }
    }

    nonisolated static func rememberedAuthorizedDevice(
        for record: PairedPhoneRecord,
        in devices: [AuthorizedADBDevice]
    ) -> AuthorizedADBDevice? {
        let exactMatches = devices.filter { device in
            device.serial == record.id
                || device.serial == record.lastAddress
                || device.serial == record.resolvedUSBSerial
                || device.serial == record.resolvedWiFiAddress
        }
        // When the same phone is live on both transports, take the wireless
        // one: it mirrors immediately with no tcpip handoff round-trip.
        if let wireless = exactMatches.first(where: { !$0.isUSB }) {
            return wireless
        }
        if let exact = exactMatches.first {
            return exact
        }

        guard record.displayName.localizedCaseInsensitiveCompare("Android device") != .orderedSame else {
            return nil
        }

        // Match on a normalized model name so trivial formatting differences
        // (underscores vs spaces, casing) between the saved name and the live
        // `adb` model don't prevent a USB-paired phone from being recognized on
        // its Wi-Fi transport.
        let normalizedName = PairedPhoneStore.normalizedDeviceName(record.displayName)
        let modelMatches = devices.filter { device in
            PairedPhoneStore.normalizedDeviceName(device.model) == normalizedName
        }
        return modelMatches.first(where: { !$0.isUSB }) ?? modelMatches.first
    }

    nonisolated static func liveWirelessAuthorizedDevice(
        for record: PairedPhoneRecord,
        in devices: [AuthorizedADBDevice]
    ) -> AuthorizedADBDevice? {
        if let device = rememberedAuthorizedDevice(for: record, in: devices),
           !device.isUSB {
            return device
        }
        return nil
    }

    nonisolated static func liveUSBAuthorizedDevice(
        for record: PairedPhoneRecord,
        in devices: [AuthorizedADBDevice]
    ) -> AuthorizedADBDevice? {
        if let usbSerial = record.resolvedUSBSerial,
           let exact = devices.first(where: { $0.isUSB && $0.serial == usbSerial }) {
            return exact
        }

        let normalizedRecordID = normalizedADBSerial(record.id)
        if let exact = devices.first(where: { device in
            device.isUSB
                && (device.serial == record.id
                    || device.serial == record.lastAddress
                    || device.serial == normalizedRecordID)
        }) {
            return exact
        }

        guard record.displayName.localizedCaseInsensitiveCompare("Android device") != .orderedSame else {
            return nil
        }
        let normalizedName = PairedPhoneStore.normalizedDeviceName(record.displayName)
        return devices.first { device in
            device.isUSB && PairedPhoneStore.normalizedDeviceName(device.model) == normalizedName
        }
    }

    struct LiveConnectionRoutes: Equatable {
        var wifiAddress: String?
        var usbSerial: String?

        var hasWiFi: Bool { wifiAddress != nil }
        var hasUSB: Bool { usbSerial != nil }

        var statusLabel: String? {
            if hasWiFi, hasUSB { return "Wi-Fi and USB available" }
            if hasWiFi { return "Wi-Fi available" }
            if hasUSB { return "USB available" }
            return nil
        }
    }

    nonisolated static func liveConnectionRoutes(
        for record: PairedPhoneRecord,
        authorizedDevices: [AuthorizedADBDevice],
        discoveredPhones: [DiscoveredPhone]
    ) -> LiveConnectionRoutes {
        let liveWiFiAddress = liveWirelessAuthorizedDevice(
            for: record,
            in: authorizedDevices
        )?.serial ?? rememberedConnectablePhone(for: record, in: discoveredPhones)?.address
        let liveUSBSerial = liveUSBAuthorizedDevice(
            for: record,
            in: authorizedDevices
        )?.serial

        return LiveConnectionRoutes(
            wifiAddress: liveWiFiAddress,
            usbSerial: liveUSBSerial
        )
    }

    nonisolated static func liveSelectedOrRememberedDevice(
        selectedSerial: String,
        pairedPhones: [PairedPhoneRecord],
        authorizedDevices: [AuthorizedADBDevice]
    ) -> AuthorizedADBDevice? {
        if let exact = authorizedDevices.first(where: { $0.serial == selectedSerial }) {
            if exact.isUSB {
                for record in recordsByMostRecent(pairedPhones) where
                    Self.recordMatchesSelectedADBSerial(record, selectedSerial: selectedSerial) {
                    if let wireless = rememberedAuthorizedDevice(for: record, in: authorizedDevices),
                       !wireless.isUSB {
                        return wireless
                    }
                }
                if let wireless = authorizedDevices.first(where: { device in
                    !device.isUSB
                        && device.model.localizedCaseInsensitiveCompare(exact.model) == .orderedSame
                        && (exact.product.isEmpty
                            || device.product.isEmpty
                            || device.product.localizedCaseInsensitiveCompare(exact.product) == .orderedSame)
                }) {
                    return wireless
                }
            }
            return exact
        }

        for record in recordsByMostRecent(pairedPhones) {
            if let device = rememberedAuthorizedDevice(for: record, in: authorizedDevices) {
                return device
            }
        }
        return nil
    }

    nonisolated static func recordForDiscoveredWiFiRoute(
        records: [PairedPhoneRecord],
        selectedDevice: MirrorDevice,
        phone: DiscoveredPhone,
        deviceName: String
    ) -> PairedPhoneRecord? {
        let ordered = recordsByMostRecent(records)
        if let remembered = ordered.first(where: {
            rememberedConnectablePhone(for: $0, in: [phone]) != nil
        }) {
            return remembered
        }
        if let selected = ordered.first(where: {
            recordMatchesSelectedDevice($0, selectedDevice: selectedDevice)
        }) {
            return selected
        }
        guard deviceName.localizedCaseInsensitiveCompare("Android device") != .orderedSame else {
            return nil
        }
        let normalizedName = PairedPhoneStore.normalizedDeviceName(deviceName)
        return ordered.first {
            PairedPhoneStore.normalizedDeviceName($0.displayName) == normalizedName
        }
    }

    nonisolated static func recordMatchesSelectedADBSerial(
        _ record: PairedPhoneRecord,
        selectedSerial: String
    ) -> Bool {
        record.id == selectedSerial
            || record.lastAddress == selectedSerial
            || record.resolvedUSBSerial == selectedSerial
            || record.resolvedWiFiAddress == selectedSerial
            || normalizedADBSerial(record.id) == selectedSerial
    }

    private nonisolated static func normalizedADBSerial(_ identifier: String) -> String {
        guard identifier.hasPrefix("adb-") else { return identifier }
        return String(identifier.dropFirst(4))
    }

    nonisolated static func isWirelessRecord(_ record: PairedPhoneRecord) -> Bool {
        record.resolvedWiFiAddress != nil
    }

    nonisolated static func rememberedConnectablePhone(
        for record: PairedPhoneRecord,
        in phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind.isConnectable }
        if let exact = connectablePhones.first(where: { $0.id == record.id }) {
            return exact
        }
        guard let wifiAddress = record.resolvedWiFiAddress else { return nil }
        guard let expectedHost = host(in: wifiAddress) else {
            return nil
        }
        if let sameHost = connectablePhones.first(where: { host(in: $0.address) == expectedHost }) {
            return sameHost
        }
        guard connectablePhones.count == 1 else {
            return nil
        }
        return connectablePhones.first
    }

    nonisolated static func hasRememberedConnectablePhone(
        records: [PairedPhoneRecord],
        in phones: [DiscoveredPhone]
    ) -> Bool {
        rememberedConnectablePhone(records: records, in: phones) != nil
    }

    nonisolated static func rememberedConnectablePhone(
        records: [PairedPhoneRecord],
        in phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        for record in recordsByMostRecent(records) {
            if let phone = rememberedConnectablePhone(for: record, in: phones) {
                return phone
            }
        }
        return nil
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

    /// The Wi-Fi interface name (`wlan0`, etc.) from `ip route` output — the
    /// token after `dev` on the wlan line. Used to read that interface's MAC.
    nonisolated static func wifiInterfaceName(in routeOutput: String) -> String? {
        let lines = routeOutput.split(whereSeparator: \.isNewline).map(String.init)
        // Prefer the same line `wifiIPAddress` keys on (wlan + a src address).
        for line in lines where line.contains("wlan") && line.contains(" src ") {
            if let iface = interfaceAfterDev(in: line) { return iface }
        }
        // Fall back to any route whose `dev` names a wlan interface.
        for line in lines {
            if let iface = interfaceAfterDev(in: line), iface.contains("wlan") {
                return iface
            }
        }
        return nil
    }

    private nonisolated static func interfaceAfterDev(in line: String) -> String? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let devIndex = parts.firstIndex(of: "dev"),
              parts.indices.contains(devIndex + 1)
        else { return nil }
        return parts[devIndex + 1]
    }

    /// The MAC from `ip addr show <iface>` / `ip link show <iface>` output — the
    /// token after `link/ether` — normalized to lowercase colon form.
    nonisolated static func macAddress(inLinkOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let index = parts.firstIndex(of: "link/ether"),
                  parts.indices.contains(index + 1)
            else { continue }
            if let mac = PairedPhoneRecord.normalizedMACAddress(parts[index + 1]) {
                return mac
            }
        }
        return nil
    }

    /// Reads the phone's Wi-Fi MAC over an existing adb transport (USB or
    /// wireless). Prefers the cheap sysfs read, falling back to `ip addr`.
    /// Blocking — call from a detached task. Returns nil if the interface is
    /// unknown or down.
    nonisolated static func resolveWiFiMACAddress(
        adb: ADBController,
        serial: String,
        routeOutput: String,
        timeout: TimeInterval = 2
    ) -> String? {
        guard let iface = wifiInterfaceName(in: routeOutput) else { return nil }
        let sysfs = adb.run(
            ["-s", serial, "shell", "cat", "/sys/class/net/\(iface)/address"],
            timeout: timeout
        )
        if let mac = PairedPhoneRecord.normalizedMACAddress(sysfs) { return mac }
        let link = adb.run(
            ["-s", serial, "shell", "ip", "addr", "show", iface],
            timeout: timeout
        )
        return macAddress(inLinkOutput: link)
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

    nonisolated static let legacyADBWirelessPort = 5555

    nonisolated static func legacyTCPIPDebuggingAddress(routeOutput: String) -> String? {
        wifiIPAddress(in: routeOutput).map { "\($0):\(legacyADBWirelessPort)" }
    }

    private nonisolated static func validPort(in output: String) -> Int? {
        let trimmedPort = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmedPort), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    nonisolated static func adbTCPIPSucceeded(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("restarting in tcp mode port")
            || lowercased.contains("already in tcp mode")
    }

    nonisolated static func waitForADBConnect(
        adb: ADBController,
        address: String,
        attempts: Int = 6,
        delayNanoseconds: UInt64 = 600_000_000
    ) async -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            let output = await Task.detached {
                adb.run(["connect", address])
            }.value

            if adbConnectSucceeded(output) {
                return true
            }
        }

        return false
    }

    /// Outcome of a wireless readiness probe. `sawNoRouteToHost` flags the
    /// macOS-side failure pattern where every connect attempt fails with "No
    /// route to host". A single no-route result can also be an ordinary transient
    /// Wi-Fi/routing miss, so don't surface the Local Network hint unless the
    /// whole probe failed that way.
    struct WirelessTargetReadiness {
        var isReady: Bool
        var connectAttempts: Int
        var noRouteToHostFailures: Int
        /// True when the raw TCP probe reached the port but `adb connect`
        /// still failed "No route to host" — the network path is fine and the
        /// denial is macOS attribution (stale/misattributed adb daemon or a
        /// revoked Local Network grant). See INVARIANTS.md rules 8–9.
        var sawReachableNoRoute: Bool = false

        var sawNoRouteToHost: Bool {
            connectAttempts > 0 && connectAttempts == noRouteToHostFailures
        }
    }

    struct LocalNetworkEndpointParts: Equatable {
        var host: String
        var port: UInt16
    }

    nonisolated static func localNetworkEndpointParts(from address: String) -> LocalNetworkEndpointParts? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }

        var host = String(trimmed[..<separator])
        let portText = String(trimmed[trimmed.index(after: separator)...])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }

        guard !host.isEmpty,
              let port = UInt16(portText),
              port > 0
        else { return nil }

        return LocalNetworkEndpointParts(host: host, port: port)
    }

    nonisolated static func wirelessADBAddress(_ candidate: String?, matches address: String) -> Bool {
        guard let candidate,
              let candidateParts = localNetworkEndpointParts(from: candidate),
              let addressParts = localNetworkEndpointParts(from: address) else {
            return false
        }

        return candidateParts.host.caseInsensitiveCompare(addressParts.host) == .orderedSame
            && candidateParts.port == addressParts.port
    }

    /// Set once a preflight dial reaches `.ready`: Local Network permission is
    /// proven granted for this process, so later preflights would only add
    /// latency (their sole job is to trigger and wait out the TCC prompt).
    /// Benign race — the worst case is one redundant preflight. Never set on
    /// failure, so a revoked permission keeps getting fresh dials.
    private nonisolated(unsafe) static var hasVerifiedLocalNetworkAccess = false

    nonisolated static func preflightLocalNetworkAccess(
        address: String,
        timeoutNanoseconds: UInt64 = 1_200_000_000
    ) async {
        guard !hasVerifiedLocalNetworkAccess else { return }
        guard let endpoint = localNetworkEndpointParts(from: address),
              let port = NWEndpoint.Port(rawValue: endpoint.port)
        else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
        let queue = DispatchQueue(label: "PhoneRelay.local-network-preflight")
        let completion = OneShotCallback()

        Logger.log("Preflighting Local Network permission for \(address)")
        await withCheckedContinuation { continuation in
            let finish: @Sendable () -> Void = {
                completion.run {
                    connection.cancel()
                    continuation.resume()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.hasVerifiedLocalNetworkAccess = true
                    finish()
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }

            connection.start(queue: queue)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                finish()
            }
        }
    }

    nonisolated static func outputIndicatesLocalNetworkBlocked(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("no route to host")
    }

    nonisolated static func adbTCPPortAcceptsConnection(
        _ address: String,
        timeoutNanoseconds: UInt64 = wirelessHandoffTCPProbeTimeoutNanoseconds
    ) async -> Bool {
        guard let endpoint = localNetworkEndpointParts(from: address) else { return true }
        guard shouldProbeADBPort(host: endpoint.host) else { return true }

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port) ?? 5555,
            using: .tcp
        )
        let queue = DispatchQueue(label: "PhoneRelay.adb-tcp-probe", qos: .utility)
        let completion = OneShotCallback()

        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { ready in
                completion.run {
                    connection.cancel()
                    continuation.resume(returning: ready)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                finish(false)
            }
        }
    }

    nonisolated static func shouldProbeADBPort(host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") {
            return true
        }

        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    nonisolated static func waitForADBWirelessTargetReady(
        adb: ADBController,
        address: String,
        attempts: Int = 8,
        delayNanoseconds: UInt64 = 700_000_000,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        primeRoute: (() async -> Void)? = nil,
        tcpPortProbe: ((String) async -> Bool)? = nil,
        maximumDuration: TimeInterval? = nil,
        connectTimeout: TimeInterval = 5,
        shellTimeout: TimeInterval = 2,
        allowADBServerRestart: Bool = true
    ) async -> Bool {
        await waitForADBWirelessTargetReadiness(
            adb: adb,
            address: address,
            attempts: attempts,
            delayNanoseconds: delayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            primeRoute: primeRoute,
            tcpPortProbe: tcpPortProbe,
            maximumDuration: maximumDuration,
            connectTimeout: connectTimeout,
            shellTimeout: shellTimeout,
            allowADBServerRestart: allowADBServerRestart
        ).isReady
    }

    /// `allowADBServerRestart` gates the one-shot `adb kill-server` escalation:
    /// it clears stale daemon state, but it also drops *every* adb transport —
    /// pass `false` whenever a live mirror session could be riding on another
    /// transport (e.g. the background USB→Wi-Fi handoff).
    nonisolated static func waitForADBWirelessTargetReadiness(
        adb: ADBController,
        address: String,
        attempts: Int = 8,
        delayNanoseconds: UInt64 = 700_000_000,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        primeRoute: (() async -> Void)? = nil,
        tcpPortProbe: ((String) async -> Bool)? = nil,
        maximumDuration: TimeInterval? = nil,
        connectTimeout: TimeInterval = 5,
        shellTimeout: TimeInterval = 2,
        allowADBServerRestart: Bool = true
    ) async -> WirelessTargetReadiness {
        guard !Task.isCancelled else {
            return WirelessTargetReadiness(
                isReady: false,
                connectAttempts: 0,
                noRouteToHostFailures: 0
            )
        }
        let deadline = maximumDuration.map { Date().addingTimeInterval(max(0, $0)) }
        func remainingBudget() -> TimeInterval? {
            guard let deadline else { return nil }
            return deadline.timeIntervalSinceNow
        }
        func boundedTimeout(_ requested: TimeInterval) -> TimeInterval? {
            guard let remaining = remainingBudget() else { return requested }
            guard remaining > 0.05 else { return nil }
            return min(requested, remaining)
        }

        if let preflightLocalNetworkAccess {
            await preflightLocalNetworkAccess(address)
        }

        var connectAttempts = 0
        var noRouteToHostFailures = 0
        var sawReachableNoRoute = false
        var restartedADBServerAfterReachableNoRoute = false
        for attempt in 0..<attempts {
            if let remaining = remainingBudget(), remaining <= 0 {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            guard !Task.isCancelled else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            if attempt > 0 {
                let sleepNanoseconds: UInt64
                if let remaining = remainingBudget() {
                    let remainingNanoseconds = UInt64(max(0, remaining) * 1_000_000_000)
                    guard remainingNanoseconds > 0 else {
                        return WirelessTargetReadiness(
                            isReady: false,
                            connectAttempts: connectAttempts,
                            noRouteToHostFailures: noRouteToHostFailures
                        )
                    }
                    sleepNanoseconds = min(delayNanoseconds, remainingNanoseconds)
                } else {
                    sleepNanoseconds = delayNanoseconds
                }
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
            guard !Task.isCancelled else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            guard boundedTimeout(connectTimeout) != nil else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }

            await primeRoute?()
            guard !Task.isCancelled else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }

            var portAcceptedThisAttempt = false
            if let tcpPortProbe {
                let portAcceptsConnection = await tcpPortProbe(address)
                portAcceptedThisAttempt = portAcceptsConnection
                if !portAcceptsConnection {
                    Logger.log("ADB Wi-Fi handoff TCP probe attempt \(attempt + 1)/\(attempts) address=\(address) output=port not ready")
                    // A dead probe usually means a dead port, so skip the
                    // expensive `adb connect`. But a phone in Wi-Fi power-save
                    // can drop the short probe while adb would still get
                    // through, so the last attempt (by count or by budget)
                    // dials regardless — otherwise a sleeping-but-reachable
                    // phone fails readiness without one real connect try.
                    let canAffordAnotherAttempt = attempt + 1 < attempts
                        && (remainingBudget().map { $0 > 1.5 } ?? true)
                    if canAffordAnotherAttempt { continue }
                }
            }

            guard let connectCommandTimeout = boundedTimeout(connectTimeout) else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            let connectOutput = await Task.detached {
                adb.run(["connect", address], timeout: connectCommandTimeout)
            }.value
            Logger.log("ADB Wi-Fi handoff connect attempt \(attempt + 1)/\(attempts) address=\(address) output=\(connectOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            if outputIndicatesLocalNetworkBlocked(connectOutput) {
                noRouteToHostFailures += 1
                if portAcceptedThisAttempt {
                    sawReachableNoRoute = true
                }
                if allowADBServerRestart,
                   tcpPortProbe != nil,
                   !restartedADBServerAfterReachableNoRoute,
                   attempt + 1 < attempts {
                    restartedADBServerAfterReachableNoRoute = true
                    Logger.log("ADB Wi-Fi handoff connect saw 'No route to host' after TCP probe accepted \(address); restarting adb server once to clear stale daemon state.")
                    await Task.detached(priority: .userInitiated) {
                        _ = adb.run(["kill-server"], timeout: 3)
                    }.value
                    await adb.ensureServerStarted()
                }
            }
            connectAttempts += 1
            guard adbConnectSucceeded(connectOutput) else {
                continue
            }

            guard let shellCommandTimeout = boundedTimeout(shellTimeout) else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            let shellOutput = await Task.detached {
                adb.run(["-s", address, "shell", "echo", "wifi-adb-ok"], timeout: shellCommandTimeout)
            }.value
            Logger.log("ADB Wi-Fi handoff shell readiness attempt \(attempt + 1)/\(attempts) address=\(address) output=\(shellOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            if shellOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "wifi-adb-ok" {
                return WirelessTargetReadiness(
                    isReady: true,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures,
                    sawReachableNoRoute: sawReachableNoRoute
                )
            }

            if attempt + 1 < attempts,
               Self.shouldDropStaleWirelessTransport(shellOutput: shellOutput),
               let disconnectTimeout = boundedTimeout(shellTimeout) {
                let disconnectOutput = await Task.detached {
                    adb.run(["disconnect", address], timeout: disconnectTimeout)
                }.value
                Logger.log("ADB Wi-Fi handoff stale transport cleanup address=\(address) output=\(disconnectOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        return WirelessTargetReadiness(
            isReady: false,
            connectAttempts: connectAttempts,
            noRouteToHostFailures: noRouteToHostFailures,
            sawReachableNoRoute: sawReachableNoRoute
        )
    }

    /// Whether a failed readiness probe means the transport is a zombie worth
    /// `adb disconnect`-ing before retrying. A transport that is merely still
    /// settling — `offline` during the post-connect handshake, or
    /// `unauthorized` while the phone shows its trust prompt — must be left
    /// alone: disconnecting it restarts the very handshake we're waiting out.
    nonisolated static func shouldDropStaleWirelessTransport(shellOutput: String) -> Bool {
        let lower = shellOutput.lowercased()
        return !(
            lower.contains("device offline")
            || lower.contains("device unauthorized")
            || lower.contains("device still authorizing")
        )
    }

    nonisolated static func primeADBWirelessRoute(
        adb: ADBController,
        usbSerial: String,
        wirelessAddress: String,
        timeout: TimeInterval = 2
    ) async {
        guard let localAddress = localIPv4Address(matchingRemoteAddress: wirelessAddress) else {
            Logger.log("ADB Wi-Fi handoff route prime skipped: no local IPv4 address matches \(wirelessAddress)")
            return
        }

        let output = await Task.detached {
            adb.run(["-s", usbSerial, "shell", "ping", "-c", "1", "-W", "1", localAddress], timeout: timeout)
        }.value
        Logger.log("ADB Wi-Fi handoff route prime usb=\(usbSerial) phoneTarget=\(wirelessAddress) macAddress=\(localAddress) output=\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    nonisolated static func localIPv4Address(matchingRemoteAddress remoteAddress: String) -> String? {
        guard let remoteHost = host(in: remoteAddress) ?? Optional(remoteAddress),
              let remote = ipv4NetworkValue(remoteHost)
        else { return nil }

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  let netmask = current.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  netmask.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }

            guard local & mask == remote & mask else { continue }

            var localAddress = in_addr(s_addr: local)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &localAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            return String(cString: buffer)
        }

        return nil
    }

    private nonisolated static func ipv4NetworkValue(_ value: String) -> in_addr_t? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        return address.s_addr
    }

    nonisolated static func wirelessPhoneMatchingUSBRoute(
        _ routeOutput: String,
        phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind.isConnectable }
        guard let wifiIP = wifiIPAddress(in: routeOutput) else {
            return nil
        }
        return connectablePhones.first { host(in: $0.address) == wifiIP }
    }

    nonisolated static func connectableWirelessPhone(
        matchingHostOf address: String,
        phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind.isConnectable }
        guard let expectedHost = host(in: address) else {
            return connectablePhones.first
        }
        return connectablePhones.first { host(in: $0.address) == expectedHost }
    }

    /// Not private: still called from AppModel.swift (pure-move split);
    /// treat as private elsewhere.
    nonisolated static func host(in address: String) -> String? {
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

    /// Not private: still called from AppModel.swift (pure-move split);
    /// treat as private elsewhere.
    static func waitForConnectableWirelessPhone(
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

    /// Not private: still called from AppModel.swift (pure-move split);
    /// treat as private elsewhere.
    nonisolated static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        return tail.split(separator: " ").first.map(String.init)
    }

    nonisolated static func specificDeviceName(_ name: String) -> String? {
        let normalized = normalizedDeviceName(name)
        guard !normalized.isEmpty else { return nil }
        let lowercased = normalized.lowercased()
        let genericNames = ["android device", "authorized device", "device", "unknown device", "unknown"]
        guard !genericNames.contains(lowercased) else { return nil }
        guard !lowercased.hasPrefix("pixel ") else { return nil }
        guard !Self.isSamsungModelCode(normalized) else { return nil }
        return normalized
    }

    nonisolated static func mirrorWindowDeviceTitle(name: String) -> String {
        let normalized = normalizedDeviceName(name)
        guard !normalized.isEmpty else { return "Android Device" }
        let lowercased = normalized.lowercased()
        let genericNames = ["android device", "authorized device", "device", "unknown device", "unknown"]
        guard !genericNames.contains(lowercased) else { return "Android Device" }
        return normalized
    }

    nonisolated static func connectionWindowTitle(
        name: String,
        isOnline: Bool,
        isMirroring: Bool
    ) -> String {
        guard isOnline || isMirroring else { return "Phone Relay" }
        return mirrorWindowDeviceTitle(name: name)
    }

    @inline(never)
    nonisolated static func connectionChoiceTitle(
        deviceLabel: String,
        state: ConnectionPillState,
        isDeviceConnected: Bool,
        isFirstTimeUSBSetup: Bool,
        isWiFiConnectionAvailable: Bool
    ) -> String {
        if isDeviceConnected {
            if deviceLabel.isEmpty {
                return "Android Device is connected"
            }
            return deviceLabel + " is connected"
        }
        if isFirstTimeUSBSetup && !isWiFiConnectionAvailable {
            return "Set up your Android phone with USB"
        }
        return "Connect your Android phone"
    }

    nonisolated static func mirrorLoadingStatusText(name: String) -> String {
        "Connecting to"
    }

    nonisolated static func mirrorLoadingDeviceTitle(name: String) -> String {
        let title = mirrorWindowDeviceTitle(name: name)
        return title == "Android Device" ? "Android phone" : title
    }

    /// Not private: still called from AppModel.swift (pure-move split);
    /// treat as private elsewhere.
    nonisolated static func normalizedDeviceName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    nonisolated static func connectedDeviceName(
        adb: ADBController,
        serial: String,
        fallback: String
    ) async -> String {
        let output = await Task.detached {
            adb.run(["devices", "-l"], timeout: adbDeviceListTimeout)
        }.value
        if let device = authorizedADBDevices(in: output).first(where: { $0.serial == serial }) {
            let modelName = mirrorWindowDeviceTitle(name: device.model)
            if modelName != "Android Device" {
                return modelName
            }
        }
        return mirrorWindowDeviceTitle(name: fallback)
    }
}
