import Foundation
@testable import PhoneRelay

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

/// Saves and restores `MirrorBehavior.explicitDeviceSetupRequired` in every
/// domain the app reads it from. "Forget all" and onboarding set it in the
/// standard domain and in each compatibility suite; restoring only the
/// standard domain left it set for later tests, whose models then started
/// with an empty device store.
struct ExplicitSetupFlagSnapshot {
    static let key = "MirrorBehavior.explicitDeviceSetupRequired"
    private let entries: [(defaults: UserDefaults, value: Any?)]

    init() {
        let domains = [UserDefaults.standard]
            + PairedPhoneStore.compatibilitySuites.compactMap { UserDefaults(suiteName: $0) }
        entries = domains.map { ($0, $0.object(forKey: Self.key)) }
    }

    /// Removes the flag everywhere, for a test that needs a normal setup.
    func clear() {
        for entry in entries {
            entry.defaults.removeObject(forKey: Self.key)
        }
    }

    func restore() {
        for entry in entries {
            if let value = entry.value {
                entry.defaults.set(value, forKey: Self.key)
            } else {
                entry.defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// A paired-phone store in a throwaway test domain, so a model that saves a
/// device never writes the shared test-host defaults later tests load from.
struct IsolatedPairedPhoneStore {
    let store: PairedPhoneStore
    private let suiteName: String

    init() {
        suiteName = "PhoneRelayTests.store.\(UUID().uuidString)"
        store = PairedPhoneStore(primaryDefaults: UserDefaults(suiteName: suiteName)!, suiteNames: [])
    }

    func cleanup() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

/// Points the app at a shell-script adb for one test, so a test never talks
/// to the real adb server (which may be serving the user's live mirror).
struct FakeADB {
    let log: URL
    private let directory: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("adb")
        log = directory.appendingPathComponent("adb.log")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        setenv("ANDROID_MIRROR_ADB_PATH", executable.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        unsetenv("ANDROID_MIRROR_ADB_PATH")
        unsetenv("ADB_FAKE_LOG")
    }
}
