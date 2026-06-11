import Foundation

/// Background mDNS poller. Calls `adb mdns services` every couple of seconds
/// and pushes the parsed phone list to a callback on the main actor.
@MainActor
final class DiscoveryService {
    private let pollPhones: @Sendable () -> [DiscoveredPhone]
    private var task: Task<Void, Never>?

    init(adb: ADBController) {
        self.pollPhones = { adb.mdnsServices() }
    }

    init(pollPhones: @escaping @Sendable () -> [DiscoveredPhone]) {
        self.pollPhones = pollPhones
    }

    deinit {
        task?.cancel()
    }

    var isRunning: Bool { task != nil }

    func start(onUpdate: @escaping @MainActor ([DiscoveredPhone]) -> Void) {
        guard task == nil else { return }
        let pollPhones = self.pollPhones
        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let phones = pollPhones()
                guard !Task.isCancelled else { return }
                await MainActor.run { onUpdate(phones) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
