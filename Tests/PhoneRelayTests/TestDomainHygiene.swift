import Foundation

/// Sweeps UserDefaults suite domains leaked by *crashed or interrupted* test
/// runs. Every current creation site cleans up via `defer` /
/// `removePersistentDomain`, but a run that dies mid-test (SIGSEGV, ^C,
/// timeout kill) skips its defers — historically ~2,500 orphaned plists
/// accumulated in ~/Library/Preferences this way.
///
/// Age-gated to one hour so a parallel test runner's live suites are never
/// touched. Invoked once per process from the suites that create domains.
enum TestDomainHygiene {
    /// Suite-name prefixes this test bundle creates (past and present).
    static let sweepablePrefixes = [
        "PhoneRelayTests.",
        "AndroidMirrorMacTests.",
        "PairedPhoneRecordMACTests"
    ]

    static let staleAge: TimeInterval = 60 * 60

    /// Touch this from `class func setUp()`; the work runs once per process.
    static let sweepOnce: Void = {
        sweep()
    }()

    static func sweep(now: Date = Date()) {
        let preferences = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Preferences", isDirectory: true)
        guard let preferences,
              let files = try? FileManager.default.contentsOfDirectory(
                at: preferences,
                includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return }

        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".plist") else { continue }
            let domain = String(name.dropLast(".plist".count))
            guard sweepablePrefixes.contains(where: { domain.hasPrefix($0) }) else { continue }
            guard let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate,
                now.timeIntervalSince(modified) > staleAge
            else { continue }
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }
}
