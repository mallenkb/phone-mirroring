import Foundation

/// Decision-oriented counters for the OCR-driven notification actions.
/// The shade-tap path is inherently coupled to Samsung's UI layout
/// (INVARIANTS.md rule 14) and will eventually drift after an Android
/// update; these counters exist so that drift is *visible* ("Open: 2 exact ·
/// 14 app-only" means the OCR path is dead) instead of a vibe. Deliberately
/// tiny: one count per action×outcome, no events, no timestamps.
final class NotificationActionMetrics: @unchecked Sendable {
    static let shared = NotificationActionMetrics()

    enum Action: String, CaseIterable {
        case open
        case reply
        case markRead
        case clear

        var title: String {
            switch self {
            case .open: return "Open"
            case .reply: return "Reply"
            case .markRead: return "Mark as read"
            case .clear: return "Clear"
            }
        }
    }

    enum Outcome: String, CaseIterable {
        /// The OCR located the notification row and drove the real action.
        case exact
        /// The row couldn't be located; the fallback ran (launch source app)
        /// or the best-effort action silently did nothing.
        case fallback
    }

    nonisolated static let defaultsKey = "Notifications.actionMetrics.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var counts: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.counts = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int]) ?? [:]
    }

    private static func key(_ action: Action, _ outcome: Outcome) -> String {
        "\(action.rawValue).\(outcome.rawValue)"
    }

    func record(_ action: Action, outcome: Outcome) {
        lock.lock()
        counts[Self.key(action, outcome), default: 0] += 1
        let snapshot = counts
        lock.unlock()
        defaults.set(snapshot, forKey: Self.defaultsKey)
    }

    func count(_ action: Action, _ outcome: Outcome) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[Self.key(action, outcome)] ?? 0
    }

    /// One line per action that has ever fired, e.g.
    /// "Open: 18 exact · 2 app-only". Empty while unused so UI stays quiet.
    var summaryLines: [String] {
        lock.lock()
        let snapshot = counts
        lock.unlock()
        return Action.allCases.compactMap { action in
            let exact = snapshot[Self.key(action, .exact)] ?? 0
            let fallback = snapshot[Self.key(action, .fallback)] ?? 0
            guard exact + fallback > 0 else { return nil }
            return "\(action.title): \(exact) exact · \(fallback) app-only"
        }
    }

    func resetForTesting() {
        lock.lock()
        counts = [:]
        lock.unlock()
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
