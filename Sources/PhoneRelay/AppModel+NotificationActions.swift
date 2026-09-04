import Foundation

// Pure move from AppModel.swift (2026-07-05): forwarded-notification actions
// and per-app notification controls, verbatim. Behavior rules live in
// INVARIANTS.md (rule 14: the OCR tap ladder and its fallbacks).
extension AppModel {

    // MARK: - Forwarded notification interactions

    nonisolated static func launchSourceAppArguments(serial: String, package: String) -> [String] {
        [
            "-s", serial,
            "shell",
            "monkey",
            "-p", package,
            "-c", "android.intent.category.LAUNCHER",
            "1"
        ]
    }

    /// Opens a forwarded notification on the phone — taps its row in the shade
    /// to fire the real content intent (a chat opens the chat), falling back to
    /// launching the source app if the row can't be located. Runs on the
    /// serialized tap queue so rapid banner clicks can't interleave, and brings
    /// the mirror on screen so the opened content is actually visible.
    // MARK: - Per-app notification controls

    nonisolated static let maxKnownNotificationApps = 60

    /// Not private: the `knownNotificationApps` property initializer lives in
    /// AppModel.swift while this helper moved to AppModel+NotificationActions.
    nonisolated static func loadKnownNotificationApps() -> [NotificationAppInfo] {
        guard let data = UserDefaults.standard.data(forKey: notificationKnownAppsDefaultsKey),
              let apps = try? JSONDecoder().decode([NotificationAppInfo].self, from: data) else {
            return []
        }
        return apps
    }

    private func persistKnownNotificationApps() {
        if let data = try? JSONEncoder().encode(knownNotificationApps) {
            UserDefaults.standard.set(data, forKey: Self.notificationKnownAppsDefaultsKey)
        }
    }

    func isNotificationPackageMuted(_ package: String) -> Bool {
        mutedNotificationPackages.contains(package)
    }

    func setNotificationPackage(_ package: String, muted: Bool) {
        guard !package.isEmpty else { return }
        if muted {
            guard mutedNotificationPackages.insert(package).inserted else { return }
        } else {
            guard mutedNotificationPackages.remove(package) != nil else { return }
        }
        UserDefaults.standard.set(
            Array(mutedNotificationPackages).sorted(),
            forKey: Self.notificationMutedPackagesDefaultsKey
        )
    }

    /// Records that `package` sent a notification so it appears in the Settings
    /// mute list. Most-recent first, deduped, and capped. No-op when nothing
    /// changes so it doesn't thrash `@Published` on every poll.
    func registerObservedNotificationApp(package: String, label: String) {
        guard !package.isEmpty else { return }
        if let index = knownNotificationApps.firstIndex(where: { $0.package == package }) {
            // Already first with the same label → nothing to do.
            if index == 0, knownNotificationApps[index].label == label { return }
            knownNotificationApps.remove(at: index)
        }
        knownNotificationApps.insert(NotificationAppInfo(package: package, label: label), at: 0)
        if knownNotificationApps.count > Self.maxKnownNotificationApps {
            knownNotificationApps.removeLast(knownNotificationApps.count - Self.maxKnownNotificationApps)
        }
        persistKnownNotificationApps()
    }

    func openSourceAppFromForwardedNotification(
        package: String,
        serial notificationSerial: String?,
        notificationKey: String? = nil,
        title: String? = nil,
        text: String? = nil
    ) {
        let package = package.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !package.isEmpty else { return }

        let serial = (notificationSerial?.isEmpty == false ? notificationSerial : nil)
            ?? selectedDevice.adbSerial
        guard let serial, !serial.isEmpty else {
            reportError("Can’t open phone app", "Connect the phone before opening a forwarded notification.")
            return
        }

        surfaceMirrorForForwardedNotification()

        let args = Self.launchSourceAppArguments(serial: serial, package: package)
        NotificationTapService.tapQueue.async {
            if NotificationTapService.tapForwardedNotificationInShade(
                serial: serial,
                notificationKey: notificationKey,
                title: title,
                text: text
            ) {
                NotificationActionMetrics.shared.record(.open, outcome: .exact)
                return
            }

            NotificationActionMetrics.shared.record(.open, outcome: .fallback)
            let result = Tooling.runResult("adb", arguments: args, timeout: 5)
            if !result.succeeded {
                Logger.log("Could not open notification source app", fields: [
                    .privateValue("package", package),
                    .privateValue("toolOutput", result.output)
                ])
            }
        }
    }

    /// Presents a native composer. Closing it retains the draft in memory.
    func replyToForwardedNotification(
        package: String,
        serial notificationSerial: String?,
        notificationKey: String? = nil,
        title: String? = nil,
        text: String? = nil,
        reply: String
    ) {
        let package = package.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = notificationSerial ?? ""
        let key = notificationKey ?? ""
        let windowKey = [serial, package, key, title ?? "", text ?? ""].joined(separator: "\u{1}")
        if let existing = notificationReplyWindows[windowKey] { existing.present(); return }
        let controller = NotificationReplyWindowController(
            appName: NotificationForwarder.appLabel(for: package), sender: title ?? "",
            message: text ?? "", draft: reply
        )
        controller.openConversation = { [weak self] in
            self?.openSourceAppFromForwardedNotification(package: package, serial: serial,
                notificationKey: key, title: title, text: text)
        }
        controller.sendReply = { [weak self] draft, completion in
            guard let self, !serial.isEmpty, !key.isEmpty,
                  self.selectedDevice.adbSerial == serial, self.mirrorSession != nil else {
                completion(.failed("Connect and open the original phone mirror before sending."))
                return
            }
            NotificationTapService.tapQueue.async { [weak self] in
                let outcome = NotificationReplyService.send(serial: serial, package: package,
                    key: key, title: title ?? "", text: text ?? "", reply: draft) { value in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard let self, self.selectedDevice.adbSerial == serial else { return false }
                            return self.mirrorSession?.pasteNotificationReply(value, serial: serial) == true
                        }
                    }
                }
                Task { @MainActor in completion(outcome) }
            }
        }
        notificationReplyWindows[windowKey] = controller
        controller.present()
    }

    /// Dismisses a forwarded notification on the phone by swiping its row out of
    /// the shade. Best-effort and OCR-driven (no app activation); silently does
    /// nothing if the row can't be located.
    func dismissForwardedNotification(
        package: String,
        serial notificationSerial: String?,
        notificationKey: String? = nil,
        title: String? = nil,
        text: String? = nil
    ) {
        guard let serial = resolvedNotificationSerial(notificationSerial) else { return }
        NotificationTapService.tapQueue.async {
            let dismissed = NotificationTapService.dismissForwardedNotificationInShade(
                serial: serial, notificationKey: notificationKey, title: title, text: text
            )
            NotificationActionMetrics.shared.record(.clear, outcome: dismissed ? .exact : .fallback)
        }
    }

    /// Marks a forwarded message-style notification as read on the phone via its
    /// inline "Mark as read" action, falling back to dismissing the row when the
    /// app doesn't expose one. Best-effort and OCR-driven.
    func markForwardedNotificationRead(
        package: String,
        serial notificationSerial: String?,
        notificationKey: String? = nil,
        title: String? = nil,
        text: String? = nil
    ) {
        guard let serial = resolvedNotificationSerial(notificationSerial) else { return }
        NotificationTapService.tapQueue.async {
            let marked = NotificationTapService.markReadForwardedNotificationInShade(
                serial: serial, notificationKey: notificationKey, title: title, text: text
            )
            NotificationActionMetrics.shared.record(.markRead, outcome: marked ? .exact : .fallback)
        }
    }

    private func resolvedNotificationSerial(_ notificationSerial: String?) -> String? {
        let serial = (notificationSerial?.isEmpty == false ? notificationSerial : nil)
            ?? selectedDevice.adbSerial
        guard let serial, !serial.isEmpty else { return nil }
        return serial
    }

    /// Brings the phone on screen for a notification the user just acted on:
    /// starts mirroring when nothing is live and a device is connected. The
    /// window itself is raised by the app delegate when it activates the app.
    private func surfaceMirrorForForwardedNotification() {
        guard !isMirroring, mirrorSession == nil, mirrorLaunchTask == nil else { return }
        guard !isPairing, !isFirstRunOnboardingActive else { return }
        guard selectedDevice.adbSerial != nil else { return }
        startMirroring(manual: true)
    }
}
