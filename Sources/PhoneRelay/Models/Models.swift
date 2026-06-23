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
        case .smooth: return 1600
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
    var recommendedFix: String
}

/// A phone we've paired with at least once. Persisted in UserDefaults so the
/// next launch can auto-reconnect just like a Bluetooth device.
struct PairedPhoneRecord: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var lastAddress: String
    var usbSerial: String?
    var wifiAddress: String?
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
        wifiAddress: String? = nil,
        wifiMACAddress: String? = nil,
        firstPaired: Date,
        lastConnected: Date,
        autoConnectSuspended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.lastAddress = lastAddress
        self.usbSerial = usbSerial ?? (Self.isWirelessADBAddress(lastAddress) ? nil : lastAddress)
        self.wifiAddress = wifiAddress ?? (Self.isWirelessADBAddress(lastAddress) ? lastAddress : nil)
        self.wifiMACAddress = Self.normalizedMACAddress(wifiMACAddress)
        self.firstPaired = firstPaired
        self.lastConnected = lastConnected
        self.autoConnectSuspended = autoConnectSuspended
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case lastAddress
        case usbSerial
        case wifiAddress
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
        wifiAddress = try container.decodeIfPresent(String.self, forKey: .wifiAddress)
            ?? (Self.isWirelessADBAddress(lastAddress) ? lastAddress : nil)
        wifiMACAddress = Self.normalizedMACAddress(
            try container.decodeIfPresent(String.self, forKey: .wifiMACAddress)
        )
        firstPaired = try container.decode(Date.self, forKey: .firstPaired)
        lastConnected = try container.decode(Date.self, forKey: .lastConnected)
        autoConnectSuspended = try container.decodeIfPresent(Bool.self, forKey: .autoConnectSuspended) ?? false
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
