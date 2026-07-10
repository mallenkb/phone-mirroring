import XCTest
@testable import PhoneRelay

/// The diagnostics bundle is an outward-facing attachment; these pin that
/// nothing identifying survives redaction — IPs, MACs, serials, device
/// names, and notification content all scrub.
final class DiagnosticsBundleRedactionTests: XCTestCase {
    func testRedactsIPv4AddressesAndMACs() {
        let text = "connect 192.168.68.52:5555 failed; mac=12:f7:73:7c:97:dc via 10.0.0.1"
        let redacted = DiagnosticsBundleService.redact(text)
        XCTAssertFalse(redacted.contains("192.168.68.52"))
        XCTAssertFalse(redacted.contains("10.0.0.1"))
        XCTAssertFalse(redacted.contains("12:f7:73:7c:97:dc"))
        XCTAssertTrue(redacted.contains("«ip»:5555"))
        XCTAssertTrue(redacted.contains("mac=«mac»"))
    }

    func testRedactsIPv6LocalHostnamesAndNetworkEndpointFields() {
        let text = "connect [fe80::8c2:4aff:fe91:2b7%en0]:5555 host=phone.lan:5555 discovered Pixel-8._adb-tls-connect._tcp.local"
        let redacted = DiagnosticsBundleService.redact(text)
        XCTAssertFalse(redacted.contains("fe80::8c2:4aff:fe91:2b7"))
        XCTAssertFalse(redacted.contains("Pixel-8._adb-tls-connect._tcp.local"))
        XCTAssertFalse(redacted.contains("phone.lan"))
        XCTAssertTrue(redacted.contains("connect «ip»:5555"))
        XCTAssertTrue(redacted.contains("host=«network-endpoint»"))
        XCTAssertTrue(redacted.contains("discovered «local-hostname»"))
    }

    func testRedactsKnownSerialsAndDeviceNames() {
        let text = "Launching native mirror serial=RFCT10ZLTAJ for SM S906B"
        let redacted = DiagnosticsBundleService.redact(
            text,
            serials: ["RFCT10ZLTAJ"],
            deviceNames: ["SM S906B"]
        )
        XCTAssertFalse(redacted.contains("RFCT10ZLTAJ"))
        XCTAssertFalse(redacted.contains("SM S906B"))
        XCTAssertTrue(redacted.contains("serial=«serial1»"))
        XCTAssertTrue(redacted.contains("for «device1»"))
    }

    func testRedactsNotificationTitleAndTextPayloads() {
        let text = "OCR match attempt title=Mom text=Dinner at 7? | rows=4"
        let redacted = DiagnosticsBundleService.redact(text)
        XCTAssertFalse(redacted.contains("Mom"))
        XCTAssertFalse(redacted.contains("Dinner at 7?"))
        XCTAssertTrue(redacted.contains("«notification-content»"))
        // Structure after the payload separator survives for debugging.
        XCTAssertTrue(redacted.contains("| rows=4"))
    }

    func testRedactsNotificationIdentityAndEmailFields() {
        let text = "Forwarded notification pkg=com.secret.chat key=0|com.secret.chat|7|tag|10337 account=person@example.com"
        let redacted = DiagnosticsBundleService.redact(text)
        XCTAssertFalse(redacted.contains("com.secret.chat"))
        XCTAssertFalse(redacted.contains("0|"))
        XCTAssertFalse(redacted.contains("person@example.com"))
        XCTAssertTrue(redacted.contains("pkg=«package»"))
        XCTAssertTrue(redacted.contains("key=«notification-key»"))
        XCTAssertTrue(redacted.contains("account=«email»"))
    }

    func testStructuredLoggerNeverWritesPrivateFieldValues() throws {
        let marker = "structured-redaction-\(UUID().uuidString)"
        let secret = "0|com.secret.chat|7|tag|10337"
        Logger.log(marker, fields: [
            .publicValue("attempt", "2"),
            .privateValue("notificationKey", secret)
        ])
        Logger.flushForTesting()

        let log = try String(contentsOf: Logger.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains(marker))
        XCTAssertTrue(log.contains("attempt=2"))
        XCTAssertTrue(log.contains("notificationKey=«private»"))
        XCTAssertFalse(log.contains(secret))
    }

    func testUnstructuredLoggerAppliesBaselineRedactionBeforeWriting() throws {
        let marker = "baseline-redaction-\(UUID().uuidString)"
        let secretSerial = "RF-\(UUID().uuidString)"
        Logger.log("\(marker) address=203.0.113.197 serial=\(secretSerial) key=0|com.secret.chat|9")
        Logger.flushForTesting()

        let log = try String(contentsOf: Logger.logURL, encoding: .utf8)
        let line = try XCTUnwrap(log.split(whereSeparator: \.isNewline).last { $0.contains(marker) })
        XCTAssertTrue(line.contains("address=«network-endpoint»"))
        XCTAssertTrue(line.contains("serial=«serial»"))
        XCTAssertTrue(line.contains("key=«notification-key»"))
        XCTAssertFalse(line.contains(secretSerial))
        XCTAssertFalse(line.contains("203.0.113.197"))
        XCTAssertFalse(line.contains("com.secret.chat"))
    }

    func testOrdinaryLogLinesSurviveUntouched() {
        let text = "[2026-07-03T16:59:18Z] ScrcpyVideoStream assigned video connection"
        XCTAssertEqual(DiagnosticsBundleService.redact(text), text)
    }
}
