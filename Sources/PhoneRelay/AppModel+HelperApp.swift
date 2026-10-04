import Foundation

/// Phone Relay Helper (AndroidHelper/) turns Wireless debugging back on after a
/// phone reboot or Wi-Fi rejoin, so the phone can be reconnected without a
/// cable. It needs WRITE_SECURE_SETTINGS, which only adb can grant. When the
/// phone is on the cable with the helper installed but not yet allowed, grant
/// it here so setup is "install the helper, plug in once".
extension AppModel {
    nonisolated static let helperPackageName = "com.mallenkb.phonerelay.helper"
    nonisolated static let writeSecureSettingsPermission = "android.permission.WRITE_SECURE_SETTINGS"

    /// `pm list packages <name>` prints `package:<name>` per match.
    nonisolated static func isHelperInstalled(packageListOutput: String) -> Bool {
        packageListOutput
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "package:\(helperPackageName)" }
    }

    /// `dumpsys package` lists runtime and development grants as
    /// `android.permission.X: granted=true`.
    nonisolated static func isHelperPermissionGranted(dumpsysPackageOutput: String) -> Bool {
        dumpsysPackageOutput
            .split(whereSeparator: \.isNewline)
            .contains { line in
                line.contains("\(writeSecureSettingsPermission): granted=true")
            }
    }

    /// Runs once per USB serial per app session.
    func grantHelperPermissionIfNeeded(usbSerial serial: String) {
        guard backgroundServicesEnabled,
              !connectionCoordinator.helperPermissionCheckedSerials.contains(serial)
        else { return }
        connectionCoordinator.helperPermissionCheckedSerials.insert(serial)
        let adb = self.adb
        Task.detached(priority: .utility) {
            let packages = adb.run(
                ["-s", serial, "shell", "pm", "list", "packages", Self.helperPackageName],
                timeout: 4
            )
            guard Self.isHelperInstalled(packageListOutput: packages) else { return }
            let dump = adb.run(["-s", serial, "shell", "dumpsys", "package", Self.helperPackageName], timeout: 6)
            if Self.isHelperPermissionGranted(dumpsysPackageOutput: dump) {
                Logger.log("Phone Relay Helper is installed and allowed on \(serial)")
                return
            }
            let result = adb.runResult(
                ["-s", serial, "shell", "pm", "grant", Self.helperPackageName, Self.writeSecureSettingsPermission],
                timeout: 6
            )
            Logger.log("Phone Relay Helper permission grant on \(serial): \(result.succeeded ? "granted" : "failed \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")")
        }
    }
}
