import XCTest
@testable import PhoneRelay

/// Pure-logic tests for the browser-backed discovery resolve cache
/// (`ADBController.resolvedPhones`). The persistent Bonjour browsers supply
/// the service list; these tests assert the resolve step is cached correctly
/// so steady-state polls spawn zero processes.
final class BonjourDiscoveryCacheTests: XCTestCase {
    private let connectService = ADBController.DNSService(
        instance: "adb-RFCT10ZLTAJ-hT5ETJ",
        serviceType: "_adb-tls-connect._tcp"
    )

    private func phone(for service: ADBController.DNSService, lastSeen: Date) -> DiscoveredPhone {
        DiscoveredPhone(
            id: service.instance,
            address: "192.168.68.54:40001",
            kind: .wirelessDebugging,
            lastSeen: lastSeen
        )
    }

    override func setUp() {
        super.setUp()
        ADBController.resetResolveCacheForTesting()
    }

    override func tearDown() {
        ADBController.resetResolveCacheForTesting()
        super.tearDown()
    }

    func testResolvesOncePerServiceAndServesFromCacheAfterwards() {
        var resolveCount = 0
        let t0 = Date()

        for pass in 0..<3 {
            let now = t0.addingTimeInterval(TimeInterval(pass))
            let phones = ADBController.resolvedPhones(
                for: [connectService],
                now: now,
                resolve: { service in
                    resolveCount += 1
                    return self.phone(for: service, lastSeen: now)
                }
            )
            XCTAssertEqual(phones.count, 1)
            XCTAssertEqual(phones.first?.address, "192.168.68.54:40001")
            // Cached entries still report a fresh lastSeen.
            XCTAssertEqual(phones.first?.lastSeen, now)
        }

        XCTAssertEqual(resolveCount, 1, "steady state must not re-resolve (or spawn processes)")
    }

    func testFailedResolveRetriesOnlyAfterRetryInterval() {
        var resolveCount = 0
        let t0 = Date()
        let failingResolver: (ADBController.DNSService) -> DiscoveredPhone? = { _ in
            resolveCount += 1
            return nil
        }

        XCTAssertTrue(ADBController.resolvedPhones(for: [connectService], now: t0, resolve: failingResolver).isEmpty)
        XCTAssertEqual(resolveCount, 1)

        // Within the retry interval: no new resolve attempt.
        _ = ADBController.resolvedPhones(
            for: [connectService],
            now: t0.addingTimeInterval(ADBController.resolveRetryInterval - 1),
            resolve: failingResolver
        )
        XCTAssertEqual(resolveCount, 1)

        // After the interval: retried.
        _ = ADBController.resolvedPhones(
            for: [connectService],
            now: t0.addingTimeInterval(ADBController.resolveRetryInterval + 1),
            resolve: failingResolver
        )
        XCTAssertEqual(resolveCount, 2)
    }

    func testServiceDisappearanceDropsCacheSoReturnReResolves() {
        var resolveCount = 0
        let t0 = Date()
        let resolver: (ADBController.DNSService) -> DiscoveredPhone? = { service in
            resolveCount += 1
            return self.phone(for: service, lastSeen: t0)
        }

        _ = ADBController.resolvedPhones(for: [connectService], now: t0, resolve: resolver)
        XCTAssertEqual(resolveCount, 1)

        // Phone stops advertising (e.g. new DHCP lease mid-move) — cache drops.
        XCTAssertTrue(ADBController.resolvedPhones(for: [], now: t0.addingTimeInterval(1), resolve: resolver).isEmpty)

        // It reappears — must re-resolve, not serve the stale address.
        _ = ADBController.resolvedPhones(for: [connectService], now: t0.addingTimeInterval(2), resolve: resolver)
        XCTAssertEqual(resolveCount, 2)
    }

    func testConnectAndPairingServicesForSameInstancePreferConnect() {
        let pairing = ADBController.DNSService(
            instance: connectService.instance,
            serviceType: "_adb-tls-pairing._tcp"
        )
        let now = Date()
        let phones = ADBController.resolvedPhones(
            for: [pairing, connectService],
            now: now,
            resolve: { service in
                DiscoveredPhone(
                    id: service.instance,
                    address: "192.168.68.54:40001",
                    kind: service.serviceType.contains("pairing") ? .pairable : .wirelessDebugging,
                    lastSeen: now
                )
            }
        )
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual(phones.first?.kind, .wirelessDebugging)
    }
}
