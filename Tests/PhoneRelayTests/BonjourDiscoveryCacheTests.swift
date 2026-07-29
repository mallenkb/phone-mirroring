import XCTest
@testable import PhoneRelay

/// Pure-logic tests for the browser-backed discovery resolve cache
/// (`ADBController.resolvedPhones`). The persistent Bonjour browsers supply
/// the service list; these tests assert the resolve step is cached correctly
/// so steady-state polls spawn zero processes, and that resolution happens
/// *off* the poll so a first sighting never blocks the 1s cycle.
final class BonjourDiscoveryCacheTests: XCTestCase {
    private let connectService = ADBController.DNSService(
        instance: "adb-RFCT10ZLTAJ-hT5ETJ",
        serviceType: "_adb-tls-connect._tcp"
    )

    /// Stand-in for the production resolve queue: runs the scheduled work
    /// immediately so a "next poll" is simply the next call in the test.
    private let immediateScheduler: (@escaping @Sendable () -> Void) -> Void = { $0() }

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
        let resolveCount = Counter()
        let t0 = Date()
        var addresses: [String?] = []

        for pass in 0..<4 {
            let now = t0.addingTimeInterval(TimeInterval(pass))
            let phones = ADBController.resolvedPhones(
                for: [connectService],
                now: now,
                resolve: { service in
                    resolveCount.increment()
                    return DiscoveredPhone(
                        id: service.instance,
                        address: "192.168.68.54:40001",
                        kind: .wirelessDebugging,
                        lastSeen: now
                    )
                },
                schedule: immediateScheduler
            )
            addresses.append(phones.first?.address)
            // Cached entries always report a fresh lastSeen.
            if let phone = phones.first {
                XCTAssertEqual(phone.lastSeen, now)
            }
        }

        // The first poll only schedules the resolve; the phone lands on the next.
        XCTAssertNil(addresses[0], "first sighting must not block the poll on dns-sd")
        XCTAssertEqual(addresses[1], "192.168.68.54:40001")
        XCTAssertEqual(addresses[3], "192.168.68.54:40001")
        XCTAssertEqual(resolveCount.value, 1, "steady state must not re-resolve (or spawn processes)")
    }

    func testPollReturnsWithoutWaitingOnResolution() {
        // Production scheduler semantics: work is queued, not run inline.
        var queued: [@Sendable () -> Void] = []
        let resolveCount = Counter()
        let now = Date()

        let phones = ADBController.resolvedPhones(
            for: [connectService],
            now: now,
            resolve: { service in
                resolveCount.increment()
                return self.phone(for: service, lastSeen: now)
            },
            schedule: { queued.append($0) }
        )

        XCTAssertTrue(phones.isEmpty)
        XCTAssertEqual(resolveCount.value, 0, "the poll must not run dns-sd itself")
        XCTAssertEqual(queued.count, 1)

        queued.forEach { $0() }
        XCTAssertEqual(resolveCount.value, 1)

        let next = ADBController.resolvedPhones(
            for: [connectService],
            now: now.addingTimeInterval(1),
            resolve: { _ in nil },
            schedule: immediateScheduler
        )
        XCTAssertEqual(next.first?.address, "192.168.68.54:40001")
    }

    func testPollsDuringAnInFlightResolveDoNotQueueDuplicateWork() {
        var queued: [@Sendable () -> Void] = []
        let t0 = Date()
        let resolver: @Sendable (ADBController.DNSService) -> DiscoveredPhone? = { _ in nil }

        for pass in 0..<3 {
            _ = ADBController.resolvedPhones(
                for: [connectService],
                now: t0.addingTimeInterval(TimeInterval(pass)),
                resolve: resolver,
                schedule: { queued.append($0) }
            )
        }

        XCTAssertEqual(queued.count, 1, "a resolve already in flight must not be queued again")
    }

    func testFailedResolveRetriesOnlyAfterRetryInterval() {
        let resolveCount = Counter()
        let t0 = Date()
        let failingResolver: @Sendable (ADBController.DNSService) -> DiscoveredPhone? = { _ in
            resolveCount.increment()
            return nil
        }

        XCTAssertTrue(
            ADBController.resolvedPhones(
                for: [connectService], now: t0,
                resolve: failingResolver, schedule: immediateScheduler
            ).isEmpty
        )
        XCTAssertEqual(resolveCount.value, 1)

        // Within the retry interval: no new resolve attempt.
        _ = ADBController.resolvedPhones(
            for: [connectService],
            now: t0.addingTimeInterval(ADBController.resolveRetryInterval - 1),
            resolve: failingResolver,
            schedule: immediateScheduler
        )
        XCTAssertEqual(resolveCount.value, 1)

        // After the interval: retried.
        _ = ADBController.resolvedPhones(
            for: [connectService],
            now: t0.addingTimeInterval(ADBController.resolveRetryInterval + 1),
            resolve: failingResolver,
            schedule: immediateScheduler
        )
        XCTAssertEqual(resolveCount.value, 2)
    }

    func testServiceDisappearanceDropsCacheSoReturnReResolves() {
        let resolveCount = Counter()
        let t0 = Date()
        let resolver: @Sendable (ADBController.DNSService) -> DiscoveredPhone? = { service in
            resolveCount.increment()
            return DiscoveredPhone(
                id: service.instance,
                address: "192.168.68.54:40001",
                kind: .wirelessDebugging,
                lastSeen: t0
            )
        }

        _ = ADBController.resolvedPhones(
            for: [connectService], now: t0,
            resolve: resolver, schedule: immediateScheduler
        )
        XCTAssertEqual(resolveCount.value, 1)

        // Phone stops advertising (e.g. new DHCP lease mid-move) — cache drops.
        XCTAssertTrue(
            ADBController.resolvedPhones(
                for: [], now: t0.addingTimeInterval(1),
                resolve: resolver, schedule: immediateScheduler
            ).isEmpty
        )

        // It reappears — must re-resolve, not serve the stale address.
        _ = ADBController.resolvedPhones(
            for: [connectService], now: t0.addingTimeInterval(2),
            resolve: resolver, schedule: immediateScheduler
        )
        XCTAssertEqual(resolveCount.value, 2)
    }

    func testResolveLandingAfterServiceDisappearsIsDiscarded() {
        var queued: [@Sendable () -> Void] = []
        let t0 = Date()

        _ = ADBController.resolvedPhones(
            for: [connectService],
            now: t0,
            resolve: { service in self.phone(for: service, lastSeen: t0) },
            schedule: { queued.append($0) }
        )
        // The phone stops advertising before the resolve comes back.
        _ = ADBController.resolvedPhones(
            for: [], now: t0.addingTimeInterval(1),
            resolve: { _ in nil }, schedule: immediateScheduler
        )
        queued.forEach { $0() }

        let phones = ADBController.resolvedPhones(
            for: [connectService],
            now: t0.addingTimeInterval(2),
            resolve: { _ in nil },
            schedule: { queued.append($0) }
        )
        XCTAssertTrue(phones.isEmpty, "a resolve for a service that went away must not surface a phone")
    }

    func testConnectAndPairingServicesForSameInstancePreferConnect() {
        let pairing = ADBController.DNSService(
            instance: connectService.instance,
            serviceType: "_adb-tls-pairing._tcp"
        )
        let now = Date()
        let resolver: @Sendable (ADBController.DNSService) -> DiscoveredPhone? = { service in
            DiscoveredPhone(
                id: service.instance,
                address: "192.168.68.54:40001",
                kind: service.serviceType.contains("pairing") ? .pairable : .wirelessDebugging,
                lastSeen: now
            )
        }

        _ = ADBController.resolvedPhones(
            for: [pairing, connectService], now: now,
            resolve: resolver, schedule: immediateScheduler
        )
        let phones = ADBController.resolvedPhones(
            for: [pairing, connectService], now: now,
            resolve: resolver, schedule: immediateScheduler
        )
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual(phones.first?.kind, .wirelessDebugging)
    }
}

/// Thread-safe counter — the resolve closures are `@Sendable` now that the
/// work can run off the calling thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
