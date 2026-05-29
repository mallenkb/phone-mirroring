import Foundation

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
        id: "demo-pixel-8",
        name: "Pixel 8 Pro",
        model: "Google Pixel",
        battery: 82,
        isCharging: false,
        network: "Local WLAN",
        lastSeen: .now,
        states: [.companionConnected, .wirelessDebuggingRequired],
        adbSerial: nil
    )
}

struct DiagnosticLine: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
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

/// A phone we've paired with at least once. Persisted in UserDefaults so the
/// next launch can auto-reconnect just like a Bluetooth device.
struct PairedPhoneRecord: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var lastAddress: String
    var firstPaired: Date
    var lastConnected: Date
}
