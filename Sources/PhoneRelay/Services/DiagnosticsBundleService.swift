import Foundation

/// Builds a shareable diagnostics zip: redacted log + connection state +
/// action counters. Redaction is not optional — the log carries IPs, MACs,
/// device serials/names, and (from OCR debugging) can carry notification
/// title/text fragments; a support attachment must leak none of them.
enum DiagnosticsBundleService {

    // MARK: - Redaction

    private nonisolated static let ipv4Pattern = try? NSRegularExpression(
        pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
    )
    private nonisolated static let macPattern = try? NSRegularExpression(
        pattern: #"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#
    )
    /// `title=…`/`text=…` payloads up to end-of-segment: OCR/tap debugging
    /// logs carry notification content in this shape.
    private nonisolated static let notificationPayloadPattern = try? NSRegularExpression(
        pattern: #"(?:\btitle=|\btext=)[^|\n]*"#
    )

    /// Scrubs network identity, device identity, and notification content
    /// from arbitrary log text. `serials`/`deviceNames` come from the paired
    /// store so even unusual formats get caught; generic IP/MAC patterns
    /// cover addresses that never made it into a record.
    nonisolated static func redact(
        _ text: String,
        serials: [String] = [],
        deviceNames: [String] = []
    ) -> String {
        var output = text
        for (index, serial) in serials.enumerated() where !serial.isEmpty {
            output = output.replacingOccurrences(of: serial, with: "«serial\(index + 1)»")
        }
        for (index, name) in deviceNames.enumerated() where !name.isEmpty {
            output = output.replacingOccurrences(of: name, with: "«device\(index + 1)»")
        }
        output = replacing(pattern: notificationPayloadPattern, in: output, with: "«notification-content»")
        output = replacing(pattern: macPattern, in: output, with: "«mac»")
        output = replacing(pattern: ipv4Pattern, in: output, with: "«ip»")
        return output
    }

    private nonisolated static func replacing(
        pattern: NSRegularExpression?,
        in text: String,
        with replacement: String
    ) -> String {
        guard let pattern else { return text }
        return pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    // MARK: - Bundle assembly

    struct Contents: Sendable {
        var logText: String
        var connectionSummary: String
        var appVersion: String
        var serials: [String]
        var deviceNames: [String]
    }

    /// Writes the redacted bundle and returns the zip URL. Blocking (file IO
    /// + `ditto`); call off the main thread.
    nonisolated static func writeBundle(_ contents: Contents, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let redactedLog = redact(
            contents.logText,
            serials: contents.serials,
            deviceNames: contents.deviceNames
        )
        let redactedSummary = redact(
            contents.connectionSummary,
            serials: contents.serials,
            deviceNames: contents.deviceNames
        )
        try redactedLog.write(
            to: staging.appendingPathComponent("PhoneRelay-redacted.log"),
            atomically: true, encoding: .utf8
        )
        try redactedSummary.write(
            to: staging.appendingPathComponent("connection-state.txt"),
            atomically: true, encoding: .utf8
        )
        try contents.appVersion.write(
            to: staging.appendingPathComponent("app-version.txt"),
            atomically: true, encoding: .utf8
        )

        try? FileManager.default.removeItem(at: destination)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "DiagnosticsBundle", code: Int(ditto.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Could not compress the diagnostics bundle."
            ])
        }
    }
}
