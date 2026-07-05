import XCTest
@testable import PhoneRelay

/// Pins the typed "last stopped because" surface: silent connect dead-ends
/// record a `ConnectionStall`, the health snapshot renders it, and a healthy
/// snapshot stays exactly as before (no extra row).
final class ConnectionStallTests: XCTestCase {
    private func snapshot(lastStall: ConnectionStall?, now: Date = Date()) -> ConnectionHealthSnapshot {
        AppModel.connectionHealthSnapshot(
            selectedSerial: nil,
            selectedNetwork: "",
            isSelectedDeviceOnline: false,
            isActivelyConnecting: false,
            hasUnauthorizedUSBDevice: false,
            authorizedDevices: [],
            discoveredPhones: [],
            localNetworkPermissionGranted: true,
            adbStatusText: "Running, no device",
            reconnectAttemptCount: 0,
            activeErrorMessage: nil,
            lastStall: lastStall,
            now: now
        )
    }

    func testHealthySnapshotHasNoStallRow() {
        XCTAssertNil(snapshot(lastStall: nil).lastStall)
    }

    func testStallRowCarriesReasonTitleAndAge() {
        let now = Date()
        let stall = ConnectionStall(
            reason: .wirelessTargetUnreachable,
            detail: "192.168.68.52:5555 did not answer the adb readiness probe.",
            at: now.addingTimeInterval(-5 * 60)
        )
        let item = snapshot(lastStall: stall, now: now).lastStall
        XCTAssertEqual(item?.id, "last-stall")
        XCTAssertEqual(item?.level, .warning)
        XCTAssertEqual(item?.value, "Phone didn't answer over Wi-Fi (5m ago)")
    }

    func testStallAgeBuckets() {
        let now = Date()
        func value(secondsAgo: TimeInterval) -> String {
            AppModel.stallValueText(
                ConnectionStall(reason: .qrDiscoveryEmpty, detail: "", at: now.addingTimeInterval(-secondsAgo)),
                now: now
            )
        }
        XCTAssertEqual(value(secondsAgo: 10), "QR pairing sees no phone (just now)")
        XCTAssertEqual(value(secondsAgo: 15 * 60), "QR pairing sees no phone (15m ago)")
        XCTAssertEqual(value(secondsAgo: 2 * 3600), "QR pairing sees no phone (2h ago)")
    }

    func testEveryReasonHasDistinctUserFacingTitle() {
        let titles = Set(ConnectionStall.Reason.allCases.map(\.title))
        XCTAssertEqual(titles.count, ConnectionStall.Reason.allCases.count)
    }

    @MainActor
    func testNoteAndClearStallLifecycle() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        XCTAssertNil(model.lastConnectionStall)

        model.noteConnectionStall(.usbNotReady, detail: "TESTSERIAL never became shell-ready.")
        XCTAssertEqual(model.lastConnectionStall?.reason, .usbNotReady)
        XCTAssertNotNil(model.connectionHealthSnapshot.lastStall)
    }
}
