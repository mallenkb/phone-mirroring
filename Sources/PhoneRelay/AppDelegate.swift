import AppKit
import Combine
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
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
    private var filesWindow: NSWindow?
    private var filesModel: FileBrowserModel?
    private var statusItem: NSStatusItem?
    private let model = AppModel()
    private var keyMonitor: Any?
    private var foregroundExitMonitor: Any?
    private var windowlessRecoveryTerminationTask: Task<Void, Never>?
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

        DispatchQueue.global(qos: .utility).async {
            PhoneFileBrowserService.cleanUpStaleTemporaryPulls()
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
        if !launchedInBackground {
            model.beginForegroundLaunchPresentation()
        }
        self.window = window

        if shouldShowFirstRunIntro {
            model.setFirstRunOnboardingActive(true)
            showFirstRunWindow()
            window.orderOut(nil)
        } else if launchedInBackground {
            // Script/background launches (`open -g … --launched-in-background`)
            // stay fully off-screen: a visible-but-unfocused card over the
            // user's work was half the "app isn't open but windows appear"
            // report. The Dock/Finder reopen path reveals everything.
            window.orderOut(nil)
        } else {
            bringLaunchWindowToFront(window)
        }

        installMainMenu()
        installStatusItem()
        installForegroundPresentationExitMonitor()
        installKeyboardScaling()
        _ = sparkleUpdaterController
    }

    /// Menu bar extra: quick access to the app, Phone Files, and the Finder
    /// mount without hunting for a window.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(
            systemSymbolName: "iphone.gen3", accessibilityDescription: "Phone Relay"
        ) {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "PR"
        }

        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open Phone Relay",
            action: #selector(statusItemOpenApp(_:)),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let files = NSMenuItem(
            title: "Phone Files",
            action: #selector(showPhoneFiles(_:)),
            keyEquivalent: ""
        )
        files.target = self
        menu.addItem(files)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Phone Relay",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func statusItemOpenApp(_ sender: Any?) {
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    }

    // MARK: - Single-instance guard

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

    /// Older siblings that should own the app session while this duplicate launch exits.
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
    /// and flood the screen with duplicate "Connecting…" windows. A second
    /// launch should behave like a normal app reopen: bring the existing
    /// instance forward and quit this short-lived duplicate without tearing
    /// down the active mirror.
    private func yieldToExistingInstanceIfNeeded() -> Bool {
        let current = Self.descriptor(for: .current)
        let runningApps = NSWorkspace.shared.runningApplications
        let candidates = runningApps.map { app in
            var descriptor = Self.descriptor(for: app)
            if !descriptor.isTerminated, !Self.isProcessAlive(descriptor.pid) {
                descriptor.isTerminated = true
            }
            return descriptor
        }
        let blockers = Self.olderDuplicateInstances(candidates: candidates, current: current)
        guard let existing = blockers
            .compactMap({ blocker in runningApps.first { $0.processIdentifier == blocker.pid } })
            .min(by: { Self.instancePrecedes(Self.descriptor(for: $0), Self.descriptor(for: $1)) })
        else {
            return false
        }

        Logger.log("Yielding duplicate Phone Relay launch to existing instance pid=\(existing.processIdentifier).")
        existing.unhide()
        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        // Let the system process the activation hand-off before this process
        // exits — terminating immediately dropped it, so the surviving
        // instance never came forward.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        NSApp.terminate(nil)
        return true
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
        let shouldTerminate = !model.isPerformingMirrorHandoffOrRecovery
        if !shouldTerminate {
            scheduleWindowlessRecoveryTermination()
        }
        return shouldTerminate
    }

    /// AppKit only asks `applicationShouldTerminateAfterLastWindowClosed` once.
    /// If that answer is `false` during a handoff, recovery can later stall and
    /// leave a zero-window process alive forever. Preserve the normal handoff
    /// gap, but terminate when it settles or after a bounded grace period.
    private func scheduleWindowlessRecoveryTermination() {
        windowlessRecoveryTerminationTask?.cancel()
        let deadline = Date().addingTimeInterval(30)
        windowlessRecoveryTerminationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }

                if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    self.windowlessRecoveryTerminationTask = nil
                    return
                }

                let recoverySettled = !self.model.isPerformingMirrorHandoffOrRecovery
                let recoveryTimedOut = Date() >= deadline
                guard recoverySettled || recoveryTimedOut else { continue }

                if recoveryTimedOut {
                    Logger.log("Windowless recovery exceeded 30 seconds; terminating stale app session.")
                }
                self.windowlessRecoveryTerminationTask = nil
                NSApp.terminate(nil)
                return
            }
        }
    }

    /// Explicit Quit must never wait for transport recovery. This also avoids
    /// document/restoration state introducing a second termination veto.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowlessRecoveryTerminationTask?.cancel()
        windowlessRecoveryTerminationTask = nil
        return .terminateNow
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLocalNetworkPermissionAfterSettingsReturn()
        if NSApp.keyWindow != nil {
            // The launch presentation accomplished its goal — ending it now
            // means the user's next app switch is never fought.
            model.endForegroundLaunchPresentation()
        } else if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            // Activated with nothing on screen (e.g. a yielding duplicate
            // handed us focus while our window was hidden) — restore it.
            raisePrimaryWindow()
        }
    }

    public func applicationDidResignActive(_ notification: Notification) {
        guard model.shouldPreserveForegroundLaunchPresentationAfterResign else {
            model.endForegroundLaunchPresentation()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.model.shouldPreserveForegroundLaunchPresentationAfterResign {
                self.raisePrimaryWindow()
            } else if !NSApp.isActive {
                self.model.endForegroundLaunchPresentation()
            }
        }
    }

    private func installForegroundPresentationExitMonitor() {
        foregroundExitMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.pointerIsInsideVisibleAppWindow() else { return }
                self.model.endForegroundLaunchPresentation()
            }
        }
    }

    private func pointerIsInsideVisibleAppWindow() -> Bool {
        let point = NSEvent.mouseLocation
        return NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(point)
        }
    }

    private func beginUserRequestedForegroundPresentation() {
        launchedInBackground = false
        model.beginForegroundLaunchPresentation()
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

        beginUserRequestedForegroundPresentation()
        bringLaunchWindowToFront(target)
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
        bringLaunchWindowToFront(target)
    }

    /// A user-initiated launch should be assertive: the app card/window comes
    /// forward and becomes key even if another app was active during startup.
    /// Borderless SwiftUI windows can miss the first activation pass while their
    /// content is still settling, so repeat once on the next run loop.
    private func bringLaunchWindowToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.unhide()
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Borderless SwiftUI windows can miss the first key pass while their
        // backing views attach — one guarded settle, not a second full raise
        // (the old window-level juggling + double invoke was the visible
        // "flash" on every launch).
        DispatchQueue.main.async {
            if window.isVisible, !window.isKeyWindow, NSApp.isActive {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Logger.log("Application will terminate")
        windowlessRecoveryTerminationTask?.cancel()
        windowlessRecoveryTerminationTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let foregroundExitMonitor {
            NSEvent.removeMonitor(foregroundExitMonitor)
            self.foregroundExitMonitor = nil
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
        viewMenu.addItem(
            NSMenuItem(
                title: "Phone Files",
                action: #selector(showPhoneFiles(_:)),
                keyEquivalent: "F"
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
                title: "Save Diagnostics Bundle…",
                action: #selector(saveDiagnosticsBundle(_:)),
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
            bringLaunchWindowToFront(firstRunWindow)
            recenterAfterLayout(firstRunWindow)
            return
        }

        let rootView = FirstRunOnboardingView { [weak self] in
            self?.model.setFirstRunOnboardingActive(false)
            self?.firstRunWindow?.orderOut(nil)
            self?.firstRunWindow = nil
            if let window = self?.window {
                self?.centerOnActiveScreen(window)
                self?.bringLaunchWindowToFront(window)
            }
            self?.model.ensureQRCodePairingSession()
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
        bringLaunchWindowToFront(window)
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

    @objc func showPhoneFiles(_ sender: Any?) {
        if let filesWindow {
            filesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            filesModel?.refresh()
            return
        }

        let browserModel = FileBrowserModel(serialProvider: { [weak model = self.model] in
            model?.selectedDevice.adbSerial
        })
        filesModel = browserModel
        let hostingView = NSHostingView(rootView: FileBrowserView(model: browserModel))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phone Files"
        window.identifier = FileBrowserView.windowIdentifier
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        filesWindow = window
    }

    @objc private func revealLastCapture(_ sender: Any?) {
        model.revealLastCapture()
    }

    /// Zips a REDACTED log + connection state for support/bug reports: IPs,
    /// MACs, serials, device names, and notification content are scrubbed
    /// before anything touches disk.
    @objc private func saveDiagnosticsBundle(_ sender: Any?) {
        let contents = model.diagnosticsBundleContents()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PhoneRelay-Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try DiagnosticsBundleService.writeBundle(contents, to: destination)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                Logger.log("Diagnostics bundle failed: \(error.localizedDescription)")
            }
        }
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

}
