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
        /// Advertising `_adb-tls-connect._tcp` — already paired or ready to connect.
        case connectable
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
    var reconnectAttempts: Item
    var recommendedFix: String
}

/// A phone we've paired with at least once. Persisted in UserDefaults so the
/// next launch can auto-reconnect just like a Bluetooth device.
struct PairedPhoneRecord: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var lastAddress: String
    var firstPaired: Date
    var lastConnected: Date
    var autoConnectSuspended: Bool

    init(
        id: String,
        displayName: String,
        lastAddress: String,
        firstPaired: Date,
        lastConnected: Date,
        autoConnectSuspended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.lastAddress = lastAddress
        self.firstPaired = firstPaired
        self.lastConnected = lastConnected
        self.autoConnectSuspended = autoConnectSuspended
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case lastAddress
        case firstPaired
        case lastConnected
        case autoConnectSuspended
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastAddress = try container.decode(String.self, forKey: .lastAddress)
        firstPaired = try container.decode(Date.self, forKey: .firstPaired)
        lastConnected = try container.decode(Date.self, forKey: .lastConnected)
        autoConnectSuspended = try container.decodeIfPresent(Bool.self, forKey: .autoConnectSuspended) ?? false
    }
}
