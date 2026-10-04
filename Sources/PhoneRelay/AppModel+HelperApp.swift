import Foundation

/// State of Phone Relay Helper on the connected phone.
enum HelperAppStatus: Equatable, Sendable {
    /// No phone checked yet this session.
    case unknown
    case notInstalled
    case installing
    /// Installed but missing WRITE_SECURE_SETTINGS (granting is automatic
    /// while a phone is connected).
    case needsPermission
    case ready
    case failed(String)

    var summary: String {
        switch self {
        case .unknown: return "Connect your phone to check"
        case .notInstalled: return "Not installed"
        case .installing: return "Installing…"
        case .needsPermission: return "Installed, finishing setup…"
        case .ready: return "Installed and active"
        case .failed(let reason): return "Couldn't install: \(reason)"
        }
    }
}

/// Phone Relay Helper (AndroidHelper/) turns Wireless debugging back on after a
/// phone reboot or Wi-Fi rejoin, so the phone reconnects without a cable. It is
/// optional: the user opts in during onboarding or in Settings, and the app
/// then installs the bundled APK the next time a phone is connected. It needs
/// WRITE_SECURE_SETTINGS, which only adb can grant, so the app grants it too.
extension AppModel {
    nonisolated static let helperPackageName = "com.mallenkb.phonerelay.helper"
    nonisolated static let writeSecureSettingsPermission = "android.permission.WRITE_SECURE_SETTINGS"
    nonisolated static let installsHelperWhenPhoneConnectsDefaultsKey = "Helper.installWhenPhoneConnects"

    nonisolated static var bundledHelperAPKURL: URL? {
        Bundle.module.url(forResource: "PhoneRelayHelper", withExtension: "apk")
    }

    /// `pm list packages <name>` prints `package:<name>` per match.
    nonisolated static func isHelperInstalled(packageListOutput: String) -> Bool {
        packageListOutput
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "package:\(helperPackageName)" }
    }

    /// `dumpsys package` lists development grants as
    /// `android.permission.X: granted=true`.
    nonisolated static func isHelperPermissionGranted(dumpsysPackageOutput: String) -> Bool {
        dumpsysPackageOutput
            .split(whereSeparator: \.isNewline)
            .contains { $0.contains("\(writeSecureSettingsPermission): granted=true") }
    }

    /// `adb install` prints "Success" on its last line when it worked.
    nonisolated static func adbInstallSucceeded(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Success" }
    }

    /// The connected phone to install on: USB first, then Wi-Fi.
    var helperTargetSerial: String? {
        latestAuthorizedADBDevices.first(where: \.isUSB)?.serial
            ?? latestAuthorizedADBDevices.first?.serial
    }

    /// Checks a newly connected phone once per session: grants the permission
    /// if the helper is installed, and installs it if the user opted in.
    func checkHelperAppIfNeeded(serial: String) {
        guard backgroundServicesEnabled,
              !connectionCoordinator.helperPermissionCheckedSerials.contains(serial)
        else { return }
        connectionCoordinator.helperPermissionCheckedSerials.insert(serial)
        runHelperSetup(serial: serial, installIfMissing: installsHelperWhenPhoneConnects)
    }

    /// "Install now" in Settings: opts in and installs on the connected phone.
    func installHelperAppNow() {
        installsHelperWhenPhoneConnects = true
        guard let serial = helperTargetSerial else {
            helperAppStatus = .unknown
            return
        }
        runHelperSetup(serial: serial, installIfMissing: true)
    }

    private func runHelperSetup(serial: String, installIfMissing: Bool) {
        guard connectionCoordinator.helperSetupTask == nil else { return }
        let adb = self.adb
        let apk = Self.bundledHelperAPKURL
        connectionCoordinator.helperSetupTask = Task { [weak self] in
            defer { self?.connectionCoordinator.helperSetupTask = nil }
            let installed = await Task.detached(priority: .utility) {
                Self.isHelperInstalled(packageListOutput: adb.run(
                    ["-s", serial, "shell", "pm", "list", "packages", Self.helperPackageName],
                    timeout: 4
                ))
            }.value
            guard let self, !Task.isCancelled else { return }

            if !installed {
                guard installIfMissing else {
                    self.helperAppStatus = .notInstalled
                    return
                }
                guard let apk else {
                    self.helperAppStatus = .failed("the helper isn't bundled with this build")
                    return
                }
                self.helperAppStatus = .installing
                let output = await Task.detached(priority: .utility) {
                    adb.run(["-s", serial, "install", "-r", apk.path], timeout: 60)
                }.value
                guard !Task.isCancelled else { return }
                guard Self.adbInstallSucceeded(output) else {
                    let reason = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "unknown error"
                    Logger.log("Phone Relay Helper install failed on \(serial): \(reason)")
                    self.helperAppStatus = .failed(reason)
                    return
                }
                Logger.log("Phone Relay Helper installed on \(serial)")
            }

            self.helperAppStatus = .needsPermission
            let granted = await Task.detached(priority: .utility) { () -> Bool in
                let dump = adb.run(["-s", serial, "shell", "dumpsys", "package", Self.helperPackageName], timeout: 6)
                if Self.isHelperPermissionGranted(dumpsysPackageOutput: dump) { return true }
                let result = adb.runResult(
                    ["-s", serial, "shell", "pm", "grant", Self.helperPackageName, Self.writeSecureSettingsPermission],
                    timeout: 6
                )
                Logger.log("Phone Relay Helper permission grant on \(serial): \(result.succeeded ? "granted" : "failed \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")")
                return result.succeeded
            }.value
            guard !Task.isCancelled else { return }
            if granted {
                // Start it once so it registers its Wi-Fi callback and turns
                // Wireless debugging on now, not only after the next reboot.
                _ = await Task.detached(priority: .utility) {
                    adb.run(["-s", serial, "shell", "am", "broadcast", "-n", "\(Self.helperPackageName)/.BootReceiver"], timeout: 6)
                }.value
                self.helperAppStatus = .ready
            } else {
                self.helperAppStatus = .failed("Android refused the permission")
            }
        }
    }
}
