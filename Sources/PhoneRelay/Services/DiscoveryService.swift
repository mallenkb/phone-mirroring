import Foundation

/// Background mDNS poller. Calls `adb mdns services` every second
/// and pushes the parsed phone list to a callback on the main actor.
@MainActor
final class DiscoveryService {
    nonisolated static let pollIntervalNanoseconds: UInt64 = 1_000_000_000
    /// Floor between polls when one runs long. The sleep is the *remainder* of
    /// the poll interval, not a flat delay on top of it — a 900ms `adb mdns
    /// services` used to push the real cadence to 1.9s — but a poll that
    /// outruns the whole interval must still not spin adb back-to-back.
    nonisolated static let minimumPollGapNanoseconds: UInt64 = 100_000_000

    /// Remaining sleep after a poll that took `elapsedNanoseconds`.
    nonisolated static func sleepNanoseconds(afterElapsed elapsedNanoseconds: UInt64) -> UInt64 {
        guard elapsedNanoseconds < pollIntervalNanoseconds else {
            return minimumPollGapNanoseconds
        }
        return max(pollIntervalNanoseconds - elapsedNanoseconds, minimumPollGapNanoseconds)
    }

    private let pollPhones: @Sendable () -> [DiscoveredPhone]
    /// Runs once before the first poll. In production this warms the adb
    /// daemon, so the first `adb mdns services` doesn't answer from a backend
    /// that is still starting up.
    private let prepare: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(adb: ADBController) {
        self.pollPhones = { adb.mdnsServices() }
        self.prepare = { await adb.primeServerIfNeeded() }
    }

    init(
        prepare: @escaping @Sendable () async -> Void = {},
        pollPhones: @escaping @Sendable () -> [DiscoveredPhone]
    ) {
        self.pollPhones = pollPhones
        self.prepare = prepare
    }

    deinit {
        task?.cancel()
    }

    func start(onUpdate: @escaping @MainActor ([DiscoveredPhone]) -> Void) {
        guard task == nil else { return }
        let pollPhones = self.pollPhones
        let prepare = self.prepare
        task = Task.detached(priority: .utility) {
            await prepare()
            while !Task.isCancelled {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let phones = pollPhones()
                guard !Task.isCancelled else { return }
                await MainActor.run { onUpdate(phones) }
                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                try? await Task.sleep(nanoseconds: Self.sleepNanoseconds(afterElapsed: elapsed))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
