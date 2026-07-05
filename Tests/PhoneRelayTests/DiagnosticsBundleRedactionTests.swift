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

    func testOrdinaryLogLinesSurviveUntouched() {
        let text = "[2026-07-03T16:59:18Z] ScrcpyVideoStream assigned video connection"
        XCTAssertEqual(DiagnosticsBundleService.redact(text), text)
    }
}
