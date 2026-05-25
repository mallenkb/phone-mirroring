import Foundation

/// Background mDNS poller. Calls `adb mdns services` every couple of seconds
/// and pushes the parsed phone list to a callback on the main actor.
@MainActor
final class DiscoveryService {
    private let adb: ADBController
    private var task: Task<Void, Never>?

    init(adb: ADBController) {
        self.adb = adb
    }

    var isRunning: Bool { task != nil }

    func start(onUpdate: @escaping @MainActor ([DiscoveredPhone]) -> Void) {
        guard task == nil else { return }
        let adb = self.adb
        task = Task {
            while !Task.isCancelled {
                let phones = adb.mdnsServices()
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
