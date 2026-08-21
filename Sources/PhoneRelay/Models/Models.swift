import Foundation

enum MirrorProfile: String, CaseIterable, Identifiable {
    case lowLatency
    case smooth
    case highQuality
    case recording
    case batteryFriendly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowLatency: return "Low Latency"
        case .smooth: return "Smooth"
        case .highQuality: return "High Quality"
        case .recording: return "Recording"
        case .batteryFriendly: return "Battery Friendly"
        }
    }

    var summary: String {
        switch self {
        case .lowLatency: return "Lower bitrate and resolution for faster interaction."
        case .smooth: return "Highest frame-rate cap for the most fluid scrolling and animation."
        case .highQuality: return "Sharper image with a higher bitrate."
        case .recording: return "Stable quality tuned for clean screen recordings."
        case .batteryFriendly: return "Lower frame rate and bitrate to reduce device load."
        }
    }

    var maxSize: Int {
        switch self {
        case .lowLatency: return 1280
        case .smooth: return 1080
        case .highQuality: return 2560
        case .recording: return 1920
        case .batteryFriendly: return 1080
        }
    }

    var bitRateMbps: Int {
        switch self {
        case .lowLatency: return 4
        case .smooth: return 8
        case .highQuality: return 16
        case .recording: return 8
        case .batteryFriendly: return 2
        }
    }

    var maxFps: Int {
        switch self {
        case .lowLatency: return 60
        case .smooth: return 120
        case .highQuality: return 0
        case .recording: return 60
        case .batteryFriendly: return 30
        }
    }

    var audioEnabled: Bool {
        switch self {
        case .batteryFriendly: return false
        case .lowLatency, .smooth, .highQuality, .recording: return true
        }
    }

    var detail: String {
        let fps = maxFps == 0 ? "Auto FPS" : "\(maxFps) Hz"
        return "\(maxSize)p · \(bitRateMbps) Mbps · \(fps)"
    }
}

enum ConnectionState: String {
    case companionConnected = "Companion Connected"
    case mirroringReady = "Mirroring Ready"
    case wirelessDebuggingRequired = "Wireless Debugging Required"
    case usbAuthorizationRequired = "USB Authorization Required"
}

/// An app Phone Relay has seen post a notification, used to build the per-app
/// mute list in Settings.
struct NotificationAppInfo: Identifiable, Equatable, Codable {
    let package: String
    var label: String
    var id: String { package }
}

struct MirrorDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    var battery: Int
    var isCharging: Bool
    var network: String
    var lastSeen: Date
    var states: [ConnectionState]
    var adbSerial: String?

    static let demo = MirrorDevice(
        id: "demo-android-mirror",
        name: "Android device",
        model: "Android",
        battery: 82,
        isCharging: false,
        network: "Local WLAN",
        lastSeen: .now,
        states: [.companionConnected, .wirelessDebuggingRequired],
        adbSerial: nil
    )
}

/// A phone seen on the local network via mDNS/Bonjour right now.
struct DiscoveredPhone: Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, Equatable {
        /// Advertising `_adb-tls-pairing._tcp` — needs a 6-digit code to pair.
        case pairable
        /// Generic connectable ADB target retained for older stored/test values.
        case connectable
        /// Advertising `_adb-tls-connect._tcp` from Android Wireless debugging.
        case wirelessDebugging
        /// Advertising `_adb._tcp` from legacy `adb tcpip 5555`.
        case legacyTCPIP

        var isConnectable: Bool {
            switch self {
            case .connectable, .wirelessDebugging, .legacyTCPIP:
                return true
            case .pairable:
                return false
            }
        }
    }
    /// mDNS service instance name; stable across Wireless-debugging sessions.
    let id: String
    var address: String
    var kind: Kind
    var lastSeen: Date
}

struct ADBQRCodePairingSession: Equatable, Hashable {
    static let servicePrefix = "studio-"
    private static let randomCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    let serviceName: String
    let password: String

    var payload: String {
        "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
    }

    static func random() -> ADBQRCodePairingSession {
        ADBQRCodePairingSession(
            serviceName: servicePrefix + randomString(length: 10),
            password: randomString(length: 12)
        )
    }

    static func pairingService(named serviceName: String, in phones: [DiscoveredPhone]) -> DiscoveredPhone? {
        phones.first { phone in
            phone.id == serviceName && phone.kind == .pairable
        }
    }

    private static func randomString(length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<length).compactMap { _ in
            randomCharacters.randomElement(using: &generator)
        }
        return String(characters)
    }
}

struct AuthorizedADBDevice: Identifiable, Equatable, Hashable {
    var id: String { serial }
    let serial: String
    let product: String
    let model: String
    let isUSB: Bool
}

/// Why the most recent background connect work stopped, in a form the
/// Connection Health panel can show. Silent dead-ends (failed readiness
/// probes, empty QR discovery, unprepared handoffs) record one of these
/// instead of only writing a log line, so "it just does nothing" is always
/// answerable from Settings.
struct ConnectionStall: Equatable {
    enum Reason: String, CaseIterable {
        case wirelessTargetUnreachable
        case wirelessRouteMissing
        case localNetworkDenied
        case handoffNotReady
        case usbNotReady
        case qrDiscoveryEmpty

        var title: String {
            switch self {
            case .wirelessTargetUnreachable: return "Phone didn't answer over Wi-Fi"
            case .wirelessRouteMissing: return "No Wi-Fi route to dial"
            case .localNetworkDenied: return "Local Network permission blocked"
            case .handoffNotReady: return "Wi-Fi handoff not ready"
            case .usbNotReady: return "USB device not ready"
            case .qrDiscoveryEmpty: return "QR pairing sees no phone"
            }
        }
    }

    var reason: Reason
    var detail: String
    var at: Date
}

struct ConnectionHealthSnapshot: Equatable {
    enum Level: Equatable {
        case ok
        case warning
        case issue
        case neutral
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var title: String
        var value: String
        var level: Level
    }

    var usbAuthorization: Item
    var wifiReachability: Item
    var localNetworkPermission: Item
    var adbStatus: Item
    var selectedTransport: Item
    var wifiHandoff: Item
    var reconnectAttempts: Item
    /// Present when background connect work recently hit a dead end; nil
    /// while healthy so the panel stays quiet.
    var lastStall: Item?
    var recommendedFix: String
}

/// A phone we've paired with at least once. Persisted in UserDefaults so the
/// next launch can auto-reconnect just like a Bluetooth device.
struct PairedPhoneRecord: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var lastAddress: String
    var usbSerial: String?
    /// Last Wi-Fi IP observed over a trusted transport such as USB. This is
    /// identity/recovery metadata only and must never be dialed until a full
    /// ADB readiness check promotes an endpoint into `wifiAddress`.
    var observedWiFiIPAddress: String?
    var wifiAddress: String?
    /// Network context and time for the last successful ADB shell on
    /// `wifiAddress`. A network-context change deprioritizes that endpoint
    /// until it is verified again.
    var wifiAddressLastVerifiedAt: Date?
    var wifiNetworkFingerprint: String?
    /// The phone's Wi-Fi MAC, normalized to lowercase colon form. Stable across
    /// DHCP lease changes on the same SSID, so it's the anchor we use to find the
    /// phone's new IP after it moves (see `WiFiAddressRecovery`).
    var wifiMACAddress: String?
    var firstPaired: Date
    var lastConnected: Date
    var autoConnectSuspended: Bool

    var resolvedUSBSerial: String? {
        usbSerial ?? (Self.isWirelessADBAddress(lastAddress) ? nil : lastAddress)
    }

    var resolvedWiFiAddress: String? {
        wifiAddress ?? (Self.isWirelessADBAddress(lastAddress) ? lastAddress : nil)
    }

    init(
        id: String,
        displayName: String,
        lastAddress: String,
        usbSerial: String? = nil,
        observedWiFiIPAddress: String? = nil,
        wifiAddress: String? = nil,
        wifiAddressLastVerifiedAt: Date? = nil,
        wifiNetworkFingerprint: String? = nil,
        wifiMACAddress: String? = nil,
        firstPaired: Date,
        lastConnected: Date,
        autoConnectSuspended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.lastAddress = lastAddress
        self.usbSerial = usbSerial ?? (Self.isWirelessADBAddress(lastAddress) ? nil : lastAddress)
        self.observedWiFiIPAddress = Self.normalizedIPv4Address(observedWiFiIPAddress)
        self.wifiAddress = wifiAddress ?? (Self.isWirelessADBAddress(lastAddress) ? lastAddress : nil)
        self.wifiAddressLastVerifiedAt = wifiAddressLastVerifiedAt
            ?? (self.wifiAddress == nil ? nil : lastConnected)
        self.wifiNetworkFingerprint = Self.normalizedOptionalValue(wifiNetworkFingerprint)
        self.wifiMACAddress = Self.normalizedMACAddress(wifiMACAddress)
        self.firstPaired = firstPaired
        self.lastConnected = lastConnected
        self.autoConnectSuspended = autoConnectSuspended
    }

    init(
        id: String,
        displayName: String,
        model: String,
        lastAddress: String,
        adbSerial: String? = nil,
        firstPaired: Date,
        lastConnected: Date,
        observedWiFiIPAddress: String? = nil,
        wifiAddress: String? = nil,
        wifiAddressLastVerifiedAt: Date? = nil,
        wifiNetworkFingerprint: String? = nil,
        wifiMACAddress: String? = nil,
        autoConnectSuspended: Bool = false
    ) {
        self.init(
            id: id,
            displayName: displayName.isEmpty ? model : displayName,
            lastAddress: lastAddress,
            usbSerial: adbSerial,
            observedWiFiIPAddress: observedWiFiIPAddress,
            wifiAddress: wifiAddress,
            wifiAddressLastVerifiedAt: wifiAddressLastVerifiedAt,
            wifiNetworkFingerprint: wifiNetworkFingerprint,
            wifiMACAddress: wifiMACAddress,
            firstPaired: firstPaired,
            lastConnected: lastConnected,
            autoConnectSuspended: autoConnectSuspended
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case lastAddress
        case usbSerial
        case observedWiFiIPAddress
        case wifiAddress
        case wifiAddressLastVerifiedAt
        case wifiNetworkFingerprint
        case wifiMACAddress
        case firstPaired
        case lastConnected
        case autoConnectSuspended
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastAddress = try container.decode(String.self, forKey: .lastAddress)
        usbSerial = try container.decodeIfPresent(String.self, forKey: .usbSerial)
            ?? (Self.isWirelessADBAddress(lastAddress) ? nil : lastAddress)
        observedWiFiIPAddress = Self.normalizedIPv4Address(
            try container.decodeIfPresent(String.self, forKey: .observedWiFiIPAddress)
        )
        wifiAddress = try container.decodeIfPresent(String.self, forKey: .wifiAddress)
            ?? (Self.isWirelessADBAddress(lastAddress) ? lastAddress : nil)
        firstPaired = try container.decode(Date.self, forKey: .firstPaired)
        lastConnected = try container.decode(Date.self, forKey: .lastConnected)
        wifiAddressLastVerifiedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .wifiAddressLastVerifiedAt
        ) ?? (wifiAddress == nil ? nil : lastConnected)
        wifiNetworkFingerprint = Self.normalizedOptionalValue(
            try container.decodeIfPresent(String.self, forKey: .wifiNetworkFingerprint)
        )
        wifiMACAddress = Self.normalizedMACAddress(
            try container.decodeIfPresent(String.self, forKey: .wifiMACAddress)
        )
        autoConnectSuspended = try container.decodeIfPresent(Bool.self, forKey: .autoConnectSuspended) ?? false
    }

    private static func normalizedOptionalValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedIPv4Address(_ raw: String?) -> String? {
        guard let candidate = normalizedOptionalValue(raw) else { return nil }
        let octets = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ octet in
                  guard !octet.isEmpty, octet.allSatisfy(\.isNumber), let value = Int(octet) else {
                      return false
                  }
                  return (0...255).contains(value)
              }) else { return nil }
        return candidate
    }

    static func isWirelessADBAddress(_ address: String) -> Bool {
        address.contains(":") || address.hasPrefix("adb-")
    }

    /// Canonical MAC form for storage and comparison: lowercase, colon-separated,
    /// each octet zero-padded to two hex digits. BSD `arp` strips leading zeros
    /// (`8:0:27:…`) while sysfs / `ip addr` keep them (`08:00:27:…`); padding lets
    /// both compare equal. Returns nil for unusable input or the all-zero MAC
    /// (which Android reports for an interface that isn't up).
    static func normalizedMACAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: ":")
        let octets = collapsed.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard octets.count == 6 else { return nil }
        var normalized: [String] = []
        for octet in octets {
            guard (1...2).contains(octet.count), octet.allSatisfy(\.isHexDigit) else { return nil }
            normalized.append(octet.count == 1 ? "0" + octet : octet)
        }
        guard normalized.contains(where: { $0 != "00" }) else { return nil }
        return normalized.joined(separator: ":")
    }
}
