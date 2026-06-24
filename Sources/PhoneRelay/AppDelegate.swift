import AppKit
import Combine
import CryptoKit
import Sparkle
import SwiftUI
import UserNotifications

/// Borderless windows refuse key status by default, which would break the
/// onboarding card's buttons and its Return-key default action.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Identity and age snapshot of a running process, lifted out of
/// `NSRunningApplication` so duplicate-instance detection stays testable.
struct AppInstanceDescriptor {
    var pid: Int32
    var bundleID: String?
    var executableName: String?
    var launchDate: Date?
    var isTerminated: Bool
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    public override init() {
        super.init()
    }

    private var window: NSWindow?
    private var firstRunWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var shortcutsWindow: NSWindow?
    private var updateCheckTask: Task<Void, Never>?
    private var updateDownloadTask: Task<Void, Never>?
    private var updateDownloadWindow: NSWindow?
    private var updateDownloadStatusLabel: NSTextField?
    private var updateDownloadProgressIndicator: NSProgressIndicator?
    private var updateDownloadActionButton: NSButton?
    private var pendingUpdateInstall: PendingUpdateInstall?
    private var automaticUpdateTimer: Timer?
    private let model = AppModel()
    private var keyMonitor: Any?
    private var launchedInBackground = false
    private weak var screenRecordingMenuItem: NSMenuItem?
    private var screenRecordingMenuCancellable: AnyCancellable?
    private lazy var sparkleUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if yieldToExistingInstanceIfNeeded() {
            return
        }
        launchedInBackground = Self.isBackgroundLaunch(arguments: CommandLine.arguments)

        if AppModel.canUseUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            registerForwardedNotificationCategories()
            // Vision's text models load lazily and the first request costs a few
            // seconds; warm them up off the launch path so the first banner
            // click/reply stays snappy.
            DispatchQueue.global(qos: .utility).async {
                NotificationTapService.warmUpTextRecognition()
            }
        } else {
            Logger.log("Skipping notification delegate registration because this process is not running from an app bundle.")
            applyDockIconForUnbundledRun()
        }

        let rootView = RootView()
            .environmentObject(model)
        let hostingView = NSHostingView(rootView: rootView)
        let shouldShowFirstRunIntro = !UserDefaults.standard.bool(forKey: "hasSeenFirstTimeUserOnboarding")
            && model.pairedPhones.isEmpty
        let initialWindowSize = AppModel.onboardingWindowSize
        let window = KeyableBorderlessWindow(
            contentRect: NSRect(origin: .zero, size: initialWindowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Phone Relay"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.contentView = hostingView
        WindowRegistrationView.applyPhoneWindowMask(to: window)
        window.minSize = initialWindowSize
        window.contentMinSize = initialWindowSize
        window.maxSize = initialWindowSize
        window.contentMaxSize = initialWindowSize
        centerOnMainScreen(window)
        model.registerConnectionWindow(window)
        self.window = window

        if shouldShowFirstRunIntro {
            model.setFirstRunOnboardingActive(true)
            showFirstRunWindow()
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }

        installMainMenu()
        installKeyboardScaling()
        NSApp.activate(ignoringOtherApps: true)
        _ = sparkleUpdaterController
    }

    // MARK: - Single-instance guard

    /// How long a fresh launch waits for an older instance to exit before
    /// concluding it is a duplicate. Sized for the restart-onboarding relaunch,
    /// where the old process quits moments after the new one starts.
    nonisolated static let duplicateInstanceExitGracePeriod: TimeInterval = 2.5

    /// Executables that count as "this app": the bundled binary and the bare
    /// SwiftPM debug binary.
    nonisolated static let phoneRelayExecutableNames: Set<String> = ["PhoneRelay", "PhoneRelayBinary"]

    nonisolated static func isBackgroundLaunch(arguments: [String]) -> Bool {
        arguments.contains("--launched-in-background")
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    public func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    public func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    nonisolated static func describesSamePhoneRelayApp(
        _ candidate: AppInstanceDescriptor,
        as current: AppInstanceDescriptor
    ) -> Bool {
        if let candidateBundleID = candidate.bundleID, let currentBundleID = current.bundleID {
            return candidateBundleID == currentBundleID
        }
        guard let candidateExecutable = candidate.executableName,
              let currentExecutable = current.executableName else {
            return false
        }
        if phoneRelayExecutableNames.contains(candidateExecutable),
           phoneRelayExecutableNames.contains(currentExecutable) {
            return true
        }
        return candidateExecutable == currentExecutable
    }

    nonisolated static func instancePrecedes(
        _ lhs: AppInstanceDescriptor,
        _ rhs: AppInstanceDescriptor
    ) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.pid < rhs.pid
        }
    }

    /// Older siblings that should be evicted before this launch continues.
    nonisolated static func olderDuplicateInstances(
        candidates: [AppInstanceDescriptor],
        current: AppInstanceDescriptor
    ) -> [AppInstanceDescriptor] {
        candidates.filter { candidate in
            candidate.pid != current.pid
                && !candidate.isTerminated
                && describesSamePhoneRelayApp(candidate, as: current)
                && instancePrecedes(candidate, current)
        }
    }

    /// Phone Relay owns exclusive resources — the adb server, scrcpy sessions,
    /// and the connection window — so concurrent copies fight over the phone
    /// and flood the screen with duplicate "Connecting…" windows. A fresh
    /// launch is the user's explicit recovery action, so it evicts any older
    /// siblings and continues as the one clean owner.
    private func yieldToExistingInstanceIfNeeded() -> Bool {
        let current = Self.descriptor(for: .current)
        let deadline = Date().addingTimeInterval(Self.duplicateInstanceExitGracePeriod)
        var requestedTerminationForPIDs = Set<Int32>()
        while true {
            // NSWorkspace's list only refreshes when the run loop turns, which
            // it can't while this wait blocks — re-verify liveness via signal 0
            // so an already-exited sibling never strands or kills this launch.
            let runningApps = NSWorkspace.shared.runningApplications
            let candidates = runningApps.map { app in
                var descriptor = Self.descriptor(for: app)
                if !descriptor.isTerminated, !Self.isProcessAlive(descriptor.pid) {
                    descriptor.isTerminated = true
                }
                return descriptor
            }
            let blockers = Self.olderDuplicateInstances(candidates: candidates, current: current)
            guard !blockers.isEmpty else {
                return false
            }

            for blocker in blockers {
                guard let app = runningApps.first(where: { $0.processIdentifier == blocker.pid }) else { continue }
                if !requestedTerminationForPIDs.contains(blocker.pid) {
                    requestedTerminationForPIDs.insert(blocker.pid)
                    Logger.log("Terminating older Phone Relay instance pid=\(blocker.pid) before continuing launch.")
                    app.terminate()
                }
            }

            // NEVER escalate to forceTerminate()/SIGKILL here. On this Mac,
            // SIGKILLing an `open`-launched (LaunchServices-managed) GUI app
            // makes LaunchServices treat it as a failed launch and relaunch it
            // ~1×/sec — an endless kill→relaunch cascade that floods the screen.
            // If an older instance ignores the graceful quit, we yield THIS
            // launch instead (below) rather than force-killing the sibling.
            if Date() >= deadline.addingTimeInterval(1.0) {
                Logger.log("Older Phone Relay instance did not exit; terminating this launch to avoid duplicate windows.")
                NSApp.terminate(nil)
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private nonisolated static func descriptor(for app: NSRunningApplication) -> AppInstanceDescriptor {
        AppInstanceDescriptor(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            executableName: app.executableURL?.lastPathComponent,
            launchDate: app.launchDate,
            isTerminated: app.isTerminated
        )
    }

    private nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive only while a USB↔Wi-Fi handoff or reconnect is mid-flight —
        // the brief windowless gap during a handoff must not quit the app. Once
        // the app is genuinely idle with no window, quit; otherwise it lurks
        // invisibly in the background and keeps throwing up mirror windows on
        // every auto-reconnect ("the app isn't even open but it happens").
        model.isPerformingMirrorHandoffOrRecovery
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLocalNetworkPermissionAfterSettingsReturn()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Behave like a normal app on every Dock-icon click — whether our window
        // is minimized, hidden behind another app, or simply not key.
        //
        // The previous `guard !flag else { return true }` bailed out whenever
        // *any* window still counted as visible. With the connection window
        // lingering, `hasVisibleWindows` was true even while the mirror sat
        // minimized — so the Dock click restored nothing (felt dead) and a
        // backgrounded app never came forward. We now always restore + raise +
        // activate the frontmost window the user thinks of as "the app",
        // skipping the floating chrome toolbar child (which can't be main).
        func isPrimary(_ candidate: NSWindow) -> Bool {
            candidate.canBecomeMain && !(candidate is MirrorToolbarWindow)
        }

        let primaries = sender.windows.filter(isPrimary)
        let target = primaries.first(where: { $0.isMiniaturized })
            ?? sender.orderedWindows.first(where: { isPrimary($0) && $0.isVisible })
            ?? primaries.first
        guard let target else { return true }

        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        target.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    /// Debug runs (Xcode / `swift run`) execute the bare binary, so the Dock
    /// shows the generic executable icon. Use the installed app's icon
    /// verbatim — macOS renders it from the compiled Icon Composer asset for
    /// the current appearance — and refresh it when the system theme changes.
    private func applyDockIconForUnbundledRun() {
        applyCurrentThemeDockIcon()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.applyCurrentThemeDockIconStatic()
            }
        }
    }

    private func applyCurrentThemeDockIcon() {
        Self.applyCurrentThemeDockIconStatic()
    }

    private static func applyCurrentThemeDockIconStatic() {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.mallenkb.PhoneRelay"
        ) {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: appURL.path)
            return
        }
        // No installed copy to borrow from — fall back to the bundled icns.
        guard let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            Logger.log("AppIcon.icns not found in resource bundle; keeping default Dock icon.")
            return
        }
        NSApp.applicationIconImage = icon
    }

    /// Registers the two banner categories: every forwarded notification offers
    /// "Open" (tap-through to the phone), and message-style ones additionally
    /// offer an inline "Reply" text field.
    private func registerForwardedNotificationCategories() {
        let openAction = UNNotificationAction(
            identifier: NotificationForwarder.Action.open,
            title: "Open",
            options: [.foreground]
        )
        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationForwarder.Action.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply"
        )
        let markReadAction = UNNotificationAction(
            identifier: NotificationForwarder.Action.markRead,
            title: "Mark as Read",
            options: []
        )
        let clearAction = UNNotificationAction(
            identifier: NotificationForwarder.Action.clear,
            title: "Clear",
            options: []
        )
        let standard = UNNotificationCategory(
            identifier: NotificationForwarder.Category.standard,
            actions: [openAction, clearAction],
            intentIdentifiers: [],
            options: []
        )
        let message = UNNotificationCategory(
            identifier: NotificationForwarder.Category.message,
            actions: [replyAction, markReadAction, openAction, clearAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([standard, message])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let package = userInfo[NotificationForwarder.UserInfoKey.sourcePackage] as? String else {
            // Not one of our forwarded notifications — just bring the app forward.
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        let serial = userInfo[NotificationForwarder.UserInfoKey.deviceSerial] as? String
        let notificationKey = userInfo[NotificationForwarder.UserInfoKey.notificationKey] as? String
        let title = userInfo[NotificationForwarder.UserInfoKey.notificationTitle] as? String
        let text = userInfo[NotificationForwarder.UserInfoKey.notificationText] as? String

        if response.actionIdentifier == NotificationForwarder.Action.reply,
           let textResponse = response as? UNTextInputNotificationResponse {
            let reply = textResponse.userText
            await MainActor.run {
                self.model.replyToForwardedNotification(
                    package: package,
                    serial: serial,
                    notificationKey: notificationKey,
                    title: title,
                    text: text,
                    reply: reply
                )
            }
            return
        }

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, NotificationForwarder.Action.open:
            await MainActor.run {
                self.model.openSourceAppFromForwardedNotification(
                    package: package,
                    serial: serial,
                    notificationKey: notificationKey,
                    title: title,
                    text: text
                )
                self.raisePrimaryWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        case NotificationForwarder.Action.clear:
            // Dismiss on the phone — no app activation; the user stays where they are.
            await MainActor.run {
                self.model.dismissForwardedNotification(
                    package: package, serial: serial,
                    notificationKey: notificationKey, title: title, text: text
                )
            }
        case NotificationForwarder.Action.markRead:
            await MainActor.run {
                self.model.markForwardedNotificationRead(
                    package: package, serial: serial,
                    notificationKey: notificationKey, title: title, text: text
                )
            }
        default:
            break
        }
    }

    /// Brings the window the user thinks of as "the app" (the mirror, or the
    /// connection window) to the front, deminiaturizing it if needed. Shared
    /// shape with `applicationShouldHandleReopen`; skips the floating toolbar
    /// child, which can't be main.
    private func raisePrimaryWindow() {
        func isPrimary(_ candidate: NSWindow) -> Bool {
            candidate.canBecomeMain && !(candidate is MirrorToolbarWindow)
        }
        let primaries = NSApp.windows.filter(isPrimary)
        let target = primaries.first(where: { $0.isMiniaturized })
            ?? NSApp.orderedWindows.first(where: { isPrimary($0) && $0.isVisible })
            ?? primaries.first
        guard let target else { return }
        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        target.makeKeyAndOrderFront(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Logger.log("Application will terminate")
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        model.shutdown()
        closeAllAppWindows()
    }

    private func closeAllAppWindows() {
        for window in NSApp.windows {
            window.delegate = nil
            window.childWindows?.forEach { child in
                child.delegate = nil
                child.close()
            }
            window.close()
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "Phone Relay", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "About Phone Relay",
                action: #selector(showAbout(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Settings...",
                action: #selector(showSettings(_:)),
                keyEquivalent: ","
            )
        )
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = sparkleUpdaterController
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Phone Relay",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(
                title: "Phone Volume Up",
                action: #selector(phoneVolumeUp(_:)),
                keyEquivalent: ""
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Phone Volume Down",
                action: #selector(phoneVolumeDown(_:)),
                keyEquivalent: ""
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Mute Phone",
                action: #selector(phoneVolumeMute(_:)),
                keyEquivalent: ""
            )
        )
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            NSMenuItem(
                title: "Go Home",
                action: #selector(goHome(_:)),
                keyEquivalent: "h"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Back",
                action: #selector(goBack(_:)),
                keyEquivalent: "["
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Recent Apps",
                action: #selector(showRecentApps(_:)),
                keyEquivalent: "]"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Take Screenshot",
                action: #selector(takeScreenshot(_:)),
                keyEquivalent: "S"
            )
        )
        let screenRecordingItem = NSMenuItem(
            title: "Start Screen Recording",
            action: #selector(toggleScreenRecording(_:)),
            keyEquivalent: "R"
        )
        screenRecordingMenuItem = screenRecordingItem
        viewMenu.addItem(screenRecordingItem)
        viewMenu.addItem(
            NSMenuItem(
                title: "Turn Phone Screen Off",
                action: #selector(togglePhoneScreen(_:)),
                keyEquivalent: "l"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Start Presentation Mode",
                action: #selector(togglePresentationMode(_:)),
                keyEquivalent: ""
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            NSMenuItem(
                title: "Increase Mirror Size by 10%",
                action: #selector(zoomIn(_:)),
                keyEquivalent: "+"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Decrease Mirror Size by 10%",
                action: #selector(zoomOut(_:)),
                keyEquivalent: "-"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Center Mirror",
                action: #selector(centerMirror(_:)),
                keyEquivalent: "0"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Turn On Always on Top",
                action: #selector(toggleAlwaysOnTop(_:)),
                keyEquivalent: ""
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            NSMenuItem(
                title: "Scan for Android Devices",
                action: #selector(scanForAndroidDevices(_:)),
                keyEquivalent: "r"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Start or Stop Mirroring",
                action: #selector(toggleMirroring(_:)),
                keyEquivalent: "m"
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            NSMenuItem(
                title: "Show Last Capture in Finder",
                action: #selector(revealLastCapture(_:)),
                keyEquivalent: ""
            )
        )
        viewItem.submenu = viewMenu

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            NSMenuItem(
                title: "Keyboard Shortcuts",
                action: #selector(showKeyboardShortcuts(_:)),
                keyEquivalent: "/"
            )
        )
        helpMenu.addItem(
            NSMenuItem(
                title: "Open Log File",
                action: #selector(openLogFile(_:)),
                keyEquivalent: ""
            )
        )
        helpMenu.addItem(
            NSMenuItem(
                title: "Privacy Policy",
                action: #selector(openPrivacyPolicy(_:)),
                keyEquivalent: ""
            )
        )
        helpMenu.addItem(
            NSMenuItem(
                title: "Support",
                action: #selector(openSupport(_:)),
                keyEquivalent: ""
            )
        )
        helpMenu.addItem(
            NSMenuItem(
                title: "View Latest Release",
                action: #selector(openLatestRelease(_:)),
                keyEquivalent: ""
            )
        )
        helpMenu.addItem(.separator())
        helpMenu.addItem(
            NSMenuItem(
                title: "Restart Onboarding",
                action: #selector(restartFirstTimeOnboarding(_:)),
                keyEquivalent: ""
            )
        )
        helpItem.submenu = helpMenu

        NSApp.mainMenu = mainMenu
        updateScreenRecordingMenuItem()
        screenRecordingMenuCancellable = model.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateScreenRecordingMenuItem()
            }
    }

    private func installKeyboardScaling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            if self?.model.forwardKeyEventToMirrorSession(event) == true {
                return AppModel.shouldConsumeForwardedKeyEvent(event) ? nil : event
            }

            guard event.type == .keyDown else {
                return event
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let key = event.charactersIgnoringModifiers else {
                return event
            }
            let hasShift = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)

            switch (key, hasShift) {
            case ("s", true):
                self?.model.takeScreenshot()
                return nil
            case ("r", true):
                self?.model.toggleScreenRecording()
                return nil
            case ("r", false):
                self?.scanForAndroidDevices(nil)
                return nil
            case ("m", false):
                self?.toggleMirroring(nil)
                return nil
            case ("l", false):
                self?.togglePhoneScreen(nil)
                return nil
            case ("+", false), ("=", false):
                self?.zoomIn(nil)
                return nil
            case ("-", false):
                self?.zoomOut(nil)
                return nil
            default:
                return event
            }
        }
    }

    private func showFirstRunWindow() {
        model.setFirstRunOnboardingActive(true)
        if let firstRunWindow {
            centerOnActiveScreen(firstRunWindow)
            firstRunWindow.makeKeyAndOrderFront(nil)
            recenterAfterLayout(firstRunWindow)
            return
        }

        let rootView = FirstRunOnboardingView { [weak self] in
            self?.model.setFirstRunOnboardingActive(false)
            self?.firstRunWindow?.orderOut(nil)
            self?.firstRunWindow = nil
            if let window = self?.window {
                self?.centerOnActiveScreen(window)
            }
            self?.window?.makeKeyAndOrderFront(nil)
            self?.model.ensureQRCodePairingSession()
            NSApp.activate(ignoringOtherApps: true)
        }
        .environmentObject(model)

        // Host in a controller that reports the SwiftUI content's own size, so
        // the window wraps the content exactly (with its built-in bottom
        // padding) and never fixed-clips the buttons.
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]

        // Borderless rounded card: the SwiftUI content draws all chrome
        // (rounded panel, quit dot), the window contributes shadow and drag.
        let window = KeyableBorderlessWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 660, height: 600)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Phone Relay"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        centerOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        recenterAfterLayout(window)
        firstRunWindow = window
    }

    private func recenterAfterLayout(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            self.centerOnActiveScreen(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak window] in
            guard let self, let window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            self.centerOnActiveScreen(window)
        }
    }

    private func centerOnMainScreen(_ window: NSWindow) {
        center(window, in: NSScreen.main?.visibleFrame)
    }

    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        center(window, in: visible)
    }

    private func center(_ window: NSWindow, in visibleFrame: NSRect?) {
        let visible = visibleFrame ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        window.setFrame(
            MirrorContentWindowController.centeredFrame(size: window.frame.size, in: visible),
            display: false,
            animate: false
        )
    }

    @objc private func scanForAndroidDevices(_ sender: Any?) {
        model.scanADBDevices()
    }

    @objc private func showAbout(_ sender: Any?) {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Phone Relay",
            .credits: NSAttributedString(
                string: "Phone Relay for Android mirrors your phone locally and forwards notifications to your Mac.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ]

        if let version, !version.isEmpty {
            options[.applicationVersion] = version
        }
        if let build, !build.isEmpty {
            options[.version] = "Build \(build)"
        }
        if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }

        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func revealLastCapture(_ sender: Any?) {
        model.revealLastCapture()
    }

    @objc private func openLogFile(_ sender: Any?) {
        model.revealLogFile()
    }

    @objc private func openPrivacyPolicy(_ sender: Any?) {
        NSWorkspace.shared.open(AppModel.privacyPolicyURL)
    }

    @objc private func openSupport(_ sender: Any?) {
        NSWorkspace.shared.open(AppModel.supportURL)
    }

    @objc private func openLatestRelease(_ sender: Any?) {
        NSWorkspace.shared.open(AppModel.latestReleaseURL)
    }

    @objc private func showKeyboardShortcuts(_ sender: Any?) {
        if let shortcutsWindow {
            shortcutsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: KeyboardShortcutsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindow = window
    }

    @objc private func restartFirstTimeOnboarding(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Restart onboarding?"
        alert.informativeText = "This clears saved onboarding and paired-phone records, then returns to the onboarding screen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Onboarding")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Everything happens in-process. Relaunching here used to race the
        // old instance against the new one — the old process's terminate ran
        // on a background queue and could fail, leaving its connection window
        // on screen next to the new instance's onboarding card.
        model.setFirstRunOnboardingActive(true)
        model.stopMirroring()
        model.resetFirstTimeUserOnboardingState()
        window?.orderOut(nil)
        firstRunWindow?.orderOut(nil)
        firstRunWindow = nil
        showFirstRunWindow()
        NSApp.activate(ignoringOtherApps: true)
    }


    @objc private func toggleMirroring(_ sender: Any?) {
        model.isMirroring ? model.stopMirroring() : model.startMirroring(manual: true)
    }

    @objc private func goHome(_ sender: Any?) {
        model.sendAndroidKey("KEYCODE_HOME")
    }

    @objc private func goBack(_ sender: Any?) {
        model.sendAndroidKey("KEYCODE_BACK")
    }

    @objc private func showRecentApps(_ sender: Any?) {
        model.sendAndroidKey("KEYCODE_APP_SWITCH")
    }

    @objc private func phoneVolumeUp(_ sender: Any?) {
        model.sendAndroidKey("KEYCODE_VOLUME_UP")
    }

    @objc private func phoneVolumeDown(_ sender: Any?) {
        model.sendAndroidKey("KEYCODE_VOLUME_DOWN")
    }

    @objc private func phoneVolumeMute(_ sender: Any?) {
        model.sendAndroidKey("KEYCODE_VOLUME_MUTE")
    }

    @objc private func takeScreenshot(_ sender: Any?) {
        model.takeScreenshot()
    }

    @objc private func toggleScreenRecording(_ sender: Any?) {
        model.toggleScreenRecording()
        updateScreenRecordingMenuItem()
    }

    @objc private func togglePhoneScreen(_ sender: Any?) {
        model.togglePhoneScreenPower()
    }

    @objc private func togglePresentationMode(_ sender: Any?) {
        model.togglePresentationMode()
    }

    @objc private func toggleAlwaysOnTop(_ sender: Any?) {
        model.toggleMirrorAlwaysOnTop()
    }

    private func updateScreenRecordingMenuItem(_ menuItem: NSMenuItem? = nil) {
        let item = menuItem ?? screenRecordingMenuItem
        item?.title = model.isRecording ? "Stop Screen Recording" : "Start Screen Recording"
        item?.state = model.isRecording ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(phoneVolumeUp(_:))?,
             #selector(phoneVolumeDown(_:))?,
             #selector(phoneVolumeMute(_:))?:
            return model.selectedDevice.adbSerial != nil
        case #selector(toggleMirroring(_:))?:
            menuItem.title = model.isMirroring ? "Stop Mirroring" : "Start Mirroring"
            return !model.isPairing && !model.isRecoveringConnection && model.selectedDevice.adbSerial != nil
        case #selector(goHome(_:))?,
             #selector(goBack(_:))?,
             #selector(showRecentApps(_:))?,
             #selector(takeScreenshot(_:))?,
             #selector(toggleScreenRecording(_:))?,
             #selector(togglePhoneScreen(_:))?,
             #selector(togglePresentationMode(_:))?,
             #selector(zoomIn(_:))?,
             #selector(zoomOut(_:))?,
             #selector(centerMirror(_:))?:
            if menuItem.action == #selector(toggleScreenRecording(_:)) {
                updateScreenRecordingMenuItem(menuItem)
                return model.hasActiveMirrorSession || model.isRecording
            }
            if menuItem.action == #selector(togglePresentationMode(_:)) {
                menuItem.title = model.presentationModeEnabled
                    ? "Stop Presentation Mode"
                    : "Start Presentation Mode"
                menuItem.state = model.presentationModeEnabled ? .on : .off
                return model.hasActiveMirrorSession || model.presentationModeEnabled
            }
            return model.hasActiveMirrorSession
        case #selector(toggleAlwaysOnTop(_:))?:
            menuItem.title = model.mirrorAlwaysOnTopEnabled
                ? "Turn Off Always on Top"
                : "Turn On Always on Top"
            menuItem.state = model.mirrorAlwaysOnTopEnabled ? .on : .off
            return true
        case #selector(revealLastCapture(_:))?:
            return model.lastCaptureURL != nil
        default:
            return true
        }
    }

    @objc private func zoomIn(_ sender: Any?) {
        model.resizeMirror(scale: 1.10)
    }

    @objc private func zoomOut(_ sender: Any?) {
        model.resizeMirror(scale: 0.90)
    }

    @objc private func centerMirror(_ sender: Any?) {
        model.centerMirrorWindow()
    }

    private func scheduleAutomaticUpdateChecks() {
        automaticUpdateTimer?.invalidate()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.runAutomaticUpdateCheckIfNeeded()
        }

        automaticUpdateTimer = Timer.scheduledTimer(withTimeInterval: Self.automaticUpdateCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runAutomaticUpdateCheckIfNeeded()
            }
        }
    }

    private func runAutomaticUpdateCheckIfNeeded() async {
        guard updateCheckTask == nil, Self.shouldRunAutomaticUpdateCheck() else { return }

        updateCheckTask = Task { [weak self] in
            await self?.runUpdateCheck(isAutomatic: true)
        }
    }

    private nonisolated static let automaticUpdateCheckInterval: TimeInterval = 24 * 60 * 60
    private nonisolated static let lastAutomaticUpdateCheckKey = "Updates.lastAutomaticCheck"

    nonisolated static func shouldRunAutomaticUpdateCheck(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        let lastCheck = defaults.object(forKey: lastAutomaticUpdateCheckKey) as? Date
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= automaticUpdateCheckInterval
    }

    private nonisolated static func markAutomaticUpdateCheckCompleted(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(now, forKey: lastAutomaticUpdateCheckKey)
    }

    private func runUpdateCheck(isAutomatic: Bool) async {
        defer { updateCheckTask = nil }

        do {
            let release = try await Self.fetchLatestRelease()
            // Record the timestamp only after a *successful* fetch. Marking it up
            // front meant a check that failed (offline, server down) still set the
            // 24h cooldown, so a transient failure suppressed retries for a day.
            if isAutomatic {
                Self.markAutomaticUpdateCheckCompleted()
            }
            await presentUpdateCheckResult(release, isAutomatic: isAutomatic)
        } catch is CancellationError {
            return
        } catch {
            guard !isAutomatic else { return }
            presentUpdateCheckFailure(error)
        }
    }

    private func presentUpdateCheckResult(_ release: ReleaseMetadata, isAutomatic: Bool) async {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let latestVersion = release.tagName

        if AppModel.isReleaseVersionNewer(latestVersion, than: currentVersion) {
            let alert = NSAlert()
            alert.messageText = "A new version of Phone Relay is available."
            alert.informativeText = "Version \(latestVersion) is available. You have \(currentVersion)."
            alert.addButton(withTitle: "Download Now")
            alert.addButton(withTitle: "Later")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let asset = release.primaryDownloadAsset else {
                    NSWorkspace.shared.open(release.htmlURL)
                    return
                }
                startUpdateDownloadWindow(release: release, asset: asset)
            default:
                break
            }
            return
        }

        guard !isAutomatic else { return }

        let alert = NSAlert()
        alert.messageText = "Phone Relay is up to date."
        alert.informativeText = "Version \(currentVersion) is the latest available release."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct PendingUpdateInstall {
        var release: ReleaseMetadata
        /// The downloaded disk image, or `nil` when the download failed and the
        /// only action left is to open the release page in a browser.
        var dmgURL: URL?
    }

    private func startUpdateDownloadWindow(release: ReleaseMetadata, asset: ReleaseAsset) {
        showUpdateDownloadWindow(release: release)
        updateDownloadTask?.cancel()
        updateDownloadTask = Task { [weak self] in
            await self?.runUpdateDownload(release: release, asset: asset)
        }
    }

    private func showUpdateDownloadWindow(release: ReleaseMetadata) {
        pendingUpdateInstall = nil

        if let updateDownloadWindow {
            updateDownloadWindow.level = .modalPanel
            updateDownloadWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 168))
            contentView.wantsLayer = true

            let iconView = NSImageView()
            iconView.image = NSApp.applicationIconImage
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = NSTextField(labelWithString: "Downloading Phone Relay \(release.tagName)")
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let statusLabel = NSTextField(labelWithString: "Preparing download...")
            statusLabel.font = .systemFont(ofSize: 13)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.translatesAutoresizingMaskIntoConstraints = false

            let progressIndicator = NSProgressIndicator()
            progressIndicator.isIndeterminate = true
            progressIndicator.style = .bar
            progressIndicator.minValue = 0
            progressIndicator.maxValue = 1
            progressIndicator.translatesAutoresizingMaskIntoConstraints = false
            progressIndicator.startAnimation(nil)

            let actionButton = NSButton(title: "Downloading...", target: self, action: #selector(installDownloadedUpdate(_:)))
            actionButton.isEnabled = false
            actionButton.bezelStyle = .rounded
            actionButton.keyEquivalent = "\r"
            actionButton.translatesAutoresizingMaskIntoConstraints = false

            let cancelButton = NSButton(title: "Later", target: self, action: #selector(cancelUpdateDownload(_:)))
            cancelButton.bezelStyle = .rounded
            cancelButton.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(iconView)
            contentView.addSubview(titleLabel)
            contentView.addSubview(statusLabel)
            contentView.addSubview(progressIndicator)
            contentView.addSubview(actionButton)
            contentView.addSubview(cancelButton)

            NSLayoutConstraint.activate([
                iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
                iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
                iconView.widthAnchor.constraint(equalToConstant: 44),
                iconView.heightAnchor.constraint(equalToConstant: 44),

                titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

                statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

                progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
                progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                progressIndicator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

                actionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
                actionButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
                actionButton.widthAnchor.constraint(equalToConstant: 132),

                cancelButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),
                cancelButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
                cancelButton.widthAnchor.constraint(equalToConstant: 92)
            ])

            let window = NSWindow(
                contentRect: contentView.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Phone Relay Update"
            window.level = .modalPanel
            window.collectionBehavior = [.moveToActiveSpace]
            window.contentView = contentView
            window.isReleasedWhenClosed = false
            // So the red close button cancels an in-flight download instead of
            // hiding the window while the transfer keeps running.
            window.delegate = self
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            updateDownloadWindow = window
            updateDownloadStatusLabel = statusLabel
            updateDownloadProgressIndicator = progressIndicator
            updateDownloadActionButton = actionButton
        }

        updateDownloadStatusLabel?.stringValue = "Preparing download..."
        updateDownloadProgressIndicator?.isIndeterminate = true
        updateDownloadProgressIndicator?.startAnimation(nil)
        updateDownloadActionButton?.title = "Downloading..."
        updateDownloadActionButton?.isEnabled = false
        updateDownloadActionButton?.keyEquivalent = ""
    }

    private func runUpdateDownload(release: ReleaseMetadata, asset: ReleaseAsset) async {
        defer { updateDownloadTask = nil }

        do {
            let downloadedDMG = try await Self.downloadUpdate(
                from: asset.browserDownloadURL,
                version: release.versionString,
                expectedSize: asset.size,
                expectedDigest: asset.digest,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.updateDownloadProgress(fraction)
                    }
                }
            )
            pendingUpdateInstall = PendingUpdateInstall(release: release, dmgURL: downloadedDMG)
            updateDownloadStatusLabel?.stringValue = "Download complete. Ready to install."
            updateDownloadProgressIndicator?.isIndeterminate = false
            updateDownloadProgressIndicator?.doubleValue = 1
            updateDownloadActionButton?.title = "Install Update"
            updateDownloadActionButton?.isEnabled = true
            updateDownloadActionButton?.keyEquivalent = "\r"
        } catch is CancellationError {
            return
        } catch {
            updateDownloadStatusLabel?.stringValue = "Download failed. \(error.localizedDescription)"
            updateDownloadProgressIndicator?.stopAnimation(nil)
            updateDownloadActionButton?.title = "View Release"
            updateDownloadActionButton?.isEnabled = true
            pendingUpdateInstall = PendingUpdateInstall(release: release, dmgURL: nil)
        }
    }

    private func updateDownloadProgress(_ fraction: Double?) {
        guard let fraction else {
            updateDownloadStatusLabel?.stringValue = "Downloading update..."
            return
        }

        updateDownloadProgressIndicator?.isIndeterminate = false
        updateDownloadProgressIndicator?.doubleValue = fraction
        updateDownloadStatusLabel?.stringValue = "Downloading update... \(Int(fraction * 100))%"
    }

    @objc private func cancelUpdateDownload(_ sender: Any?) {
        updateDownloadTask?.cancel()
        updateDownloadTask = nil
        pendingUpdateInstall = nil
        updateDownloadWindow?.orderOut(nil)
    }

    @objc private func installDownloadedUpdate(_ sender: Any?) {
        guard let pending = pendingUpdateInstall else { return }
        guard let dmgURL = pending.dmgURL else {
            NSWorkspace.shared.open(pending.release.htmlURL)
            return
        }

        updateDownloadActionButton?.isEnabled = false
        updateDownloadActionButton?.title = "Installing..."
        updateDownloadStatusLabel?.stringValue = "Installing update..."
        updateDownloadProgressIndicator?.isIndeterminate = true
        updateDownloadProgressIndicator?.startAnimation(nil)

        // Mounting the DMG and `ditto`-copying a whole app bundle blocks for a few
        // seconds — running it inline would freeze the window (the "Installing..."
        // label set above would never even repaint), so do it off the main actor.
        Task { [weak self] in
            do {
                let installedAppURL = try await Task.detached(priority: .userInitiated) {
                    try Self.installUpdate(fromDMG: dmgURL)
                }.value
                guard let self else { return }
                self.updateDownloadWindow?.orderOut(nil)
                self.presentUpdateReadyToRestart(installedAppURL: installedAppURL, version: pending.release.tagName)
            } catch {
                guard let self else { return }
                self.updateDownloadProgressIndicator?.stopAnimation(nil)
                self.updateDownloadActionButton?.isEnabled = true
                self.updateDownloadActionButton?.title = "Install Update"
                self.presentUpdateInstallFailure(error, release: pending.release)
            }
        }
    }

    private func presentUpdateReadyToRestart(installedAppURL: URL, version: String) {
        let alert = NSAlert()
        alert.messageText = "Phone Relay \(version) is ready."
        alert.informativeText = "Restart Phone Relay now to finish using the update, or keep working and restart later."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // The updated app lives at the same bundle path as this still-running copy.
        // With the default configuration, LaunchServices would just reactivate the
        // current (about-to-quit) instance instead of spawning the new one, so the
        // "restart" would simply quit. Force a fresh instance, and only terminate
        // ourselves once the launch request has been dispatched — the new copy's
        // single-instance guard waits out our exit before taking over.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installedAppURL, configuration: configuration) { _, error in
            if let error {
                Logger.log("Could not relaunch updated Phone Relay: \(error.localizedDescription)")
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func presentUpdateInstallFailure(_ error: Error, release: ReleaseMetadata) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Install Update"
        let details = Self.updateErrorMessage(error)
        Logger.log("Update install failed: \(details)")
        alert.informativeText = """
        Phone Relay downloaded the update, but could not install it automatically.

        \(details)
        """
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func presentUpdateCheckFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = "Phone Relay could not reach the update service. \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private nonisolated static func fetchLatestRelease() async throws -> ReleaseMetadata {
        var request = URLRequest(url: AppModel.releaseMetadataURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateCheckError.invalidStatusCode(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(ReleaseMetadata.self, from: data)
    }

    private struct ReleaseMetadata: Decodable {
        var tagName: String
        var htmlURL: URL
        var assets: [ReleaseAsset]

        var versionString: String {
            tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }

        var primaryDownloadAsset: ReleaseAsset? {
            assets.first { $0.name == "PhoneRelay-\(versionString).dmg" }
                ?? assets.first { $0.name == "PhoneRelay.dmg" }
                ?? assets.first { $0.name.hasPrefix("PhoneRelay") && $0.name.hasSuffix(".dmg") }
        }

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let websiteContainer = try decoder.container(keyedBy: WebsiteCodingKeys.self)

            tagName = try container.decodeIfPresent(String.self, forKey: .tagName)
                ?? websiteContainer.decode(String.self, forKey: .tagName)

            if let htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL) {
                self.htmlURL = htmlURL
            } else if let releaseURL = try websiteContainer.decodeIfPresent(URL.self, forKey: .releaseURL) {
                htmlURL = releaseURL
            } else {
                htmlURL = AppModel.latestReleaseURL
            }

            if let assets = try container.decodeIfPresent([ReleaseAsset].self, forKey: .assets) {
                self.assets = assets
            } else if let asset = try websiteContainer.decodeIfPresent(ReleaseAsset.self, forKey: .asset) {
                self.assets = [asset]
            } else {
                self.assets = []
            }
        }

        private enum WebsiteCodingKeys: String, CodingKey {
            case tagName
            case releaseURL = "releaseUrl"
            case asset
        }
    }

    private struct ReleaseAsset: Decodable {
        var name: String
        var browserDownloadURL: URL
        var size: Int64?
        var digest: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case url
            case size
            case digest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            browserDownloadURL = try container.decodeIfPresent(URL.self, forKey: .browserDownloadURL)
                ?? container.decode(URL.self, forKey: .url)
            size = try container.decodeIfPresent(Int64.self, forKey: .size)
            digest = try container.decodeIfPresent(String.self, forKey: .digest)
        }
    }

    private enum UpdateCheckError: LocalizedError {
        case invalidStatusCode(Int)
        case appNotBundled
        case invalidDownloadedDiskImage(String)
        case missingMountedApp
        case processFailed(command: String, status: Int32, output: String)
        case fileOperationFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidStatusCode(statusCode):
                "The update service returned HTTP \(statusCode)."
            case .appNotBundled:
                "Automatic installation only works when Phone Relay is running from a .app bundle."
            case let .invalidDownloadedDiskImage(message):
                "The downloaded update is not a valid disk image. \(message)"
            case .missingMountedApp:
                "The downloaded disk image did not contain Phone Relay.app."
            case let .processFailed(command, status, output):
                "\(command) exited with status \(status). \(output)"
            case let .fileOperationFailed(message):
                message
            }
        }
    }

    private nonisolated static func updateErrorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(nsError.localizedDescription) \(underlying.localizedDescription)"
        }
        return nsError.localizedDescription
    }

    private nonisolated static func downloadUpdate(
        from url: URL,
        version: String,
        expectedSize: Int64?,
        expectedDigest: String?,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let downloadsDirectory = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destinationURL = downloadsDirectory.appendingPathComponent("PhoneRelay-\(version).dmg")
        let downloader = UpdateDownloader(destinationURL: destinationURL, onProgress: progress)
        let downloadedURL = try await downloader.download(from: url)
        do {
            try validateDownloadedUpdate(downloadedURL, expectedSize: expectedSize, expectedDigest: expectedDigest)
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw error
        }
        return downloadedURL
    }

    /// Streams an update DMG to disk with a `URLSessionDownloadTask`. The earlier
    /// implementation iterated `URLSession.bytes` one `UInt8` at a time and issued
    /// a `write` syscall per byte, which turned a ~16 MB download into millions of
    /// syscalls and pinned a CPU core for minutes. A download task transfers at
    /// native speed, reports real byte-progress, and supports cancellation.
    private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destinationURL: URL
        private let onProgress: @Sendable (Double?) -> Void
        /// All three are only ever touched on the session's serial delegate queue
        /// (or written once before `task.resume()`), so no extra locking is needed.
        private var continuation: CheckedContinuation<URL, Error>?
        private var statusError: UpdateCheckError?
        private var savedURL: URL?

        init(destinationURL: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
            self.destinationURL = destinationURL
            self.onProgress = onProgress
        }

        func download(from url: URL) async throws -> URL {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            // The session retains its delegate (self); invalidate so it's released.
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: request)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            if totalBytesExpectedToWrite > 0 {
                onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            } else {
                onProgress(nil)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // A non-2xx response still "downloads" successfully — to a temp file
            // holding the error body. Reject it so we never rename an HTML error
            // page to .dmg and try to mount it.
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                statusError = .invalidStatusCode(http.statusCode)
                return
            }
            // The temp file is removed as soon as this method returns, so the move
            // has to happen synchronously here.
            do {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: location, to: destinationURL)
                savedURL = destinationURL
            } catch {
                statusError = .fileOperationFailed("Could not save the downloaded update: \(error.localizedDescription)")
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            defer { continuation = nil }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                // Surface cancellation as Swift's CancellationError so the caller's
                // `catch is CancellationError` stays silent instead of showing a
                // "Download failed" message.
                continuation?.resume(throwing: CancellationError())
            } else if let error {
                continuation?.resume(throwing: error)
            } else if let statusError {
                continuation?.resume(throwing: statusError)
            } else if let savedURL {
                onProgress(1)
                continuation?.resume(returning: savedURL)
            } else {
                continuation?.resume(throwing: UpdateCheckError.fileOperationFailed("The update download did not produce a file."))
            }
        }
    }

    private nonisolated static func installUpdate(fromDMG dmgURL: URL) throws -> URL {
        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            throw UpdateCheckError.appNotBundled
        }

        try validateDownloadedUpdate(dmgURL, expectedSize: nil, expectedDigest: nil)
        let mountURL = try attachDiskImage(dmgURL)
        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountURL.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountURL)
        }

        let mountedApps = try FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: nil
        ).filter { url in
            isPhoneRelayAppBundle(url)
        }
        guard let stagedAppURL = mountedApps.first else {
            throw UpdateCheckError.missingMountedApp
        }

        let parentDirectory = currentAppURL.deletingLastPathComponent()
        let installURL = parentDirectory.appendingPathComponent(currentAppURL.lastPathComponent)
        let backupURL = parentDirectory.appendingPathComponent("PhoneRelay.previous.app")

        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try FileManager.default.removeItem(at: backupURL)
            } catch {
                throw UpdateCheckError.fileOperationFailed("Could not remove old backup app at \(backupURL.path): \(updateErrorMessage(error))")
            }
        }
        if FileManager.default.fileExists(atPath: installURL.path) {
            do {
                try FileManager.default.moveItem(at: installURL, to: backupURL)
            } catch {
                throw UpdateCheckError.fileOperationFailed("Could not move current app from \(installURL.path) to \(backupURL.path): \(updateErrorMessage(error))")
            }
        }

        do {
            try runProcess("/usr/bin/ditto", arguments: [stagedAppURL.path, installURL.path])
            // The DMG was downloaded from the internet, so the copied app inherits
            // `com.apple.quarantine`. Clear it so the relaunched copy isn't blocked
            // by Gatekeeper with "Phone Relay can't be opened". (Best-effort: a
            // properly Developer-ID-signed + notarized build still launches even if
            // this fails; an unsigned build needs a real signature regardless.)
            _ = try? runProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", installURL.path])
            try? FileManager.default.removeItem(at: backupURL)
            // The installed copy is what matters now; don't leave the DMG behind in
            // ~/Downloads.
            try? FileManager.default.removeItem(at: dmgURL)
            return installURL
        } catch {
            if !FileManager.default.fileExists(atPath: installURL.path),
               FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: installURL)
            }
            throw error
        }
    }

    private nonisolated static func attachDiskImage(_ dmgURL: URL) throws -> URL {
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)

        do {
            _ = try runProcess(
                "/usr/bin/hdiutil",
                arguments: ["attach", dmgURL.path, "-nobrowse", "-mountpoint", mountURL.path, "-quiet"]
            )
            return mountURL
        } catch {
            try? FileManager.default.removeItem(at: mountURL)
            throw error
        }
    }

    private nonisolated static func isPhoneRelayAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "")
                .localizedCaseInsensitiveContains("PhoneRelay")
        }
        return info["CFBundleIdentifier"] as? String == "com.mallenkb.PhoneRelay"
    }

    private nonisolated static func validateDownloadedUpdate(
        _ dmgURL: URL,
        expectedSize: Int64?,
        expectedDigest: String?
    ) throws {
        guard FileManager.default.fileExists(atPath: dmgURL.path) else {
            throw UpdateCheckError.invalidDownloadedDiskImage("The file no longer exists. Download the update again.")
        }
        if let expectedSize {
            let actualSize = try (FileManager.default.attributesOfItem(atPath: dmgURL.path)[.size] as? NSNumber)?.int64Value
            if actualSize != expectedSize {
                throw UpdateCheckError.invalidDownloadedDiskImage("Expected \(expectedSize) bytes, but downloaded \(actualSize ?? 0) bytes. Download the update again.")
            }
        }
        if let expectedDigest,
           let expectedSHA256 = normalizedSHA256Digest(expectedDigest) {
            let data = try Data(contentsOf: dmgURL)
            let actualSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actualSHA256.lowercased() != expectedSHA256 {
                throw UpdateCheckError.invalidDownloadedDiskImage("The SHA-256 checksum did not match. Download the update again.")
            }
        }

        do {
            _ = try runProcess("/usr/bin/hdiutil", arguments: ["verify", dmgURL.path])
        } catch {
            throw UpdateCheckError.invalidDownloadedDiskImage(updateErrorMessage(error))
        }
    }

    private nonisolated static func normalizedSHA256Digest(_ digest: String) -> String? {
        let lowercased = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = lowercased.hasPrefix("sha256:") ? String(lowercased.dropFirst("sha256:".count)) : lowercased
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return value
    }

    /// Reference box so the background drain threads can hand captured bytes back
    /// across the wait without tripping concurrency checks.
    private final class DataBox: @unchecked Sendable { var data = Data() }

    @discardableResult
    private nonisolated static func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes concurrently *before* waiting: a child that writes more
        // than the ~64 KB pipe buffer (a verbose `ditto`/`hdiutil` error) would
        // otherwise block on a full pipe while we block in waitUntilExit — deadlock.
        let outBox = DataBox()
        let errBox = DataBox()
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "phonerelay.update.process-drain", attributes: .concurrent)
        let outHandle = outputPipe.fileHandleForReading
        let errHandle = errorPipe.fileHandleForReading
        drainGroup.enter()
        drainQueue.async { outBox.data = outHandle.readDataToEndOfFile(); drainGroup.leave() }
        drainGroup.enter()
        drainQueue.async { errBox.data = errHandle.readDataToEndOfFile(); drainGroup.leave() }

        do {
            try process.run()
        } catch {
            outHandle.closeFile()
            errHandle.closeFile()
            drainGroup.wait()
            throw error
        }
        process.waitUntilExit()
        drainGroup.wait()

        let output = String(data: outBox.data, encoding: .utf8) ?? ""
        let errorOutput = String(data: errBox.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            throw UpdateCheckError.processFailed(
                command: command,
                status: process.terminationStatus,
                output: errorOutput.isEmpty ? output : errorOutput
            )
        }
        return output
    }

}

extension AppDelegate: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        // Closing the update window via its red button should also stop an
        // in-flight download — otherwise the transfer keeps running against a
        // hidden window. Scoped to the update window so other windows are
        // unaffected.
        guard (notification.object as? NSWindow) === updateDownloadWindow else { return }
        updateDownloadTask?.cancel()
        updateDownloadTask = nil
        pendingUpdateInstall = nil
    }
}
