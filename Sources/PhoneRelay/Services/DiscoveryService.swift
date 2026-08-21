import Foundation

/// Background mDNS discovery coordinator. Bonjour and resolver changes wake it
/// immediately; a one-second timer remains as a bounded recovery poll.
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
    /// Runs once before the first poll. Production starts the persistent
    /// Bonjour browsers here; adb warm-up belongs to the device watcher so it
    /// cannot delay Wi-Fi presence.
    private let prepare: @Sendable () async -> Void
    private var periodicTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var deferredPollTask: Task<Void, Never>?
    private var discoveryObserverID: UUID?
    private var onUpdate: (@MainActor ([DiscoveredPhone]) -> Void)?
    private var isPrepared = false
    private var pollPending = false
    private var lastPollFinishedAt: UInt64?
    private var generation = 0

    init(adb: ADBController) {
        self.pollPhones = { adb.mdnsServices() }
        self.prepare = {
            // Bonjour is independent of adb and must be allowed to publish
            // presence immediately, even while the daemon starts elsewhere.
            _ = BonjourServiceMonitor.shared.serviceSnapshot()
        }
    }

    init(
        prepare: @escaping @Sendable () async -> Void = {},
        pollPhones: @escaping @Sendable () -> [DiscoveredPhone]
    ) {
        self.pollPhones = pollPhones
        self.prepare = prepare
    }

    deinit {
        periodicTask?.cancel()
        pollTask?.cancel()
        deferredPollTask?.cancel()
        if let discoveryObserverID {
            ADBController.removeDiscoveryObserver(discoveryObserverID)
        }
    }

    func start(onUpdate: @escaping @MainActor ([DiscoveredPhone]) -> Void) {
        guard periodicTask == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        self.onUpdate = onUpdate
        isPrepared = false
        pollPending = false

        discoveryObserverID = ADBController.addDiscoveryObserver { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestPoll()
            }
        }

        let prepare = self.prepare
        periodicTask = Task { @MainActor [weak self] in
            await prepare()
            guard let self,
                  !Task.isCancelled,
                  self.generation == currentGeneration else { return }
            self.isPrepared = true
            self.requestPoll()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                guard !Task.isCancelled,
                      self.generation == currentGeneration else { return }
                self.requestPoll()
            }
        }
    }

    func stop() {
        generation &+= 1
        periodicTask?.cancel()
        periodicTask = nil
        pollTask?.cancel()
        pollTask = nil
        deferredPollTask?.cancel()
        deferredPollTask = nil
        if let discoveryObserverID {
            ADBController.removeDiscoveryObserver(discoveryObserverID)
            self.discoveryObserverID = nil
        }
        onUpdate = nil
        isPrepared = false
        pollPending = false
        lastPollFinishedAt = nil
    }

    /// Coalesces timer and Bonjour/resolve events into one off-main poll. A
    /// source change no longer waits for the next one-second timer, while the
    /// minimum gap still protects adb if a poll itself overruns.
    private func requestPoll() {
        guard periodicTask != nil else { return }
        guard isPrepared else {
            pollPending = true
            return
        }
        guard pollTask == nil else {
            pollPending = true
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if let lastPollFinishedAt {
            let elapsed = now - lastPollFinishedAt
            if elapsed < Self.minimumPollGapNanoseconds {
                pollPending = true
                guard deferredPollTask == nil else { return }
                let delay = Self.minimumPollGapNanoseconds - elapsed
                let currentGeneration = generation
                deferredPollTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    guard let self,
                          !Task.isCancelled,
                          self.generation == currentGeneration else { return }
                    self.deferredPollTask = nil
                    self.requestPoll()
                }
                return
            }
        }

        deferredPollTask?.cancel()
        deferredPollTask = nil
        pollPending = false
        let pollPhones = self.pollPhones
        let currentGeneration = generation
        pollTask = Task { @MainActor [weak self] in
            let phones = await Task.detached(priority: .utility) {
                pollPhones()
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.generation == currentGeneration else { return }
            self.pollTask = nil
            self.lastPollFinishedAt = DispatchTime.now().uptimeNanoseconds
            self.onUpdate?(phones)
            if self.pollPending {
                self.requestPoll()
            }
        }
    }
}
