import AppKit
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
    private static let latestReleaseURL = URL(string: "https://github.com/mallenkb/phone-mirroring/releases/latest")!
    private static let releaseWorkflowURL = URL(string: "https://github.com/mallenkb/phone-mirroring/actions/workflows/pages.yml")!

    public override init() {
        super.init()
    }

    private var window: NSWindow?
    private var firstRunWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var shortcutsWindow: NSWindow?
    private var noticesWindow: NSWindow?
    private let model = AppModel()
    private var keyMonitor: Any?
    private var launchedInBackground = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if yieldToExistingInstanceIfNeeded() {
            return
        }
        launchedInBackground = Self.isBackgroundLaunch(arguments: CommandLine.arguments)

        if AppModel.canUseUserNotifications {
            UNUserNotificationCenter.current().delegate = self
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
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialWindowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "PhoneRelay"
        window.isReleasedWhenClosed = false
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
        } else if launchedInBackground {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }

        installMainMenu()
        installKeyboardScaling()
        if !launchedInBackground {
            NSApp.activate(ignoringOtherApps: true)
        }
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

    /// The still-running older sibling this instance must defer to, or nil when
    /// this instance is the rightful single copy.
    nonisolated static func blockingDuplicateInstance(
        candidates: [AppInstanceDescriptor],
        current: AppInstanceDescriptor
    ) -> AppInstanceDescriptor? {
        candidates.first { candidate in
            candidate.pid != current.pid
                && !candidate.isTerminated
                && describesSamePhoneRelayApp(candidate, as: current)
                && instancePrecedes(candidate, current)
        }
    }

    /// PhoneRelay owns exclusive resources — the adb server, scrcpy sessions,
    /// and the connection window — so concurrent copies fight over the phone
    /// and flood the screen with duplicate "Connecting…" windows (e.g. from
    /// `open -n`, or a dev build launched next to the installed app). The
    /// newest instance yields: it waits briefly for older instances to exit
    /// (covering the restart-onboarding relaunch handoff), then activates the
    /// survivor and terminates itself.
    private func yieldToExistingInstanceIfNeeded() -> Bool {
        let current = Self.descriptor(for: .current)
        let deadline = Date().addingTimeInterval(Self.duplicateInstanceExitGracePeriod)
        while true {
            // NSWorkspace's list only refreshes when the run loop turns, which
            // it can't while this wait blocks — re-verify liveness via signal 0
            // so an already-exited sibling never strands or kills this launch.
            let candidates = NSWorkspace.shared.runningApplications.map { app in
                var descriptor = Self.descriptor(for: app)
                if !descriptor.isTerminated, !Self.isProcessAlive(descriptor.pid) {
                    descriptor.isTerminated = true
                }
                return descriptor
            }
            guard let blocker = Self.blockingDuplicateInstance(candidates: candidates, current: current) else {
                return false
            }
            guard Date() < deadline else {
                Logger.log("Another PhoneRelay instance (pid \(blocker.pid)) is already running; terminating this duplicate copy.")
                NSWorkspace.shared.runningApplications
                    .first { $0.processIdentifier == blocker.pid }?
                    .activate(options: [])
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
        false
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        Logger.log("Application will terminate")
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        model.shutdown()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "PhoneRelay", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "About PhoneRelay",
                action: #selector(showAbout(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(
            NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdates(_:)),
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
        appMenu.addItem(
            NSMenuItem(
                title: "Third-Party Notices...",
                action: #selector(showThirdPartyNotices(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit PhoneRelay",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
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
        viewMenu.addItem(
            NSMenuItem(
                title: "Start or Stop Screen Recording",
                action: #selector(toggleScreenRecording(_:)),
                keyEquivalent: "R"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Turn Phone Screen Off or On",
                action: #selector(togglePhoneScreen(_:)),
                keyEquivalent: "l"
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
                title: "Open Release Workflow",
                action: #selector(openReleaseWorkflow(_:)),
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
    }

    private func installKeyboardScaling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            if self?.model.forwardKeyEventToMirrorSession(event) == true {
                return nil
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
        window.title = "PhoneRelay"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        centerOnActiveScreen(window)
        if launchedInBackground {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
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
            .applicationName: "PhoneRelay",
            .credits: NSAttributedString(
                string: "PhoneRelay for Android mirrors your phone locally and forwards notifications to your Mac.",
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

    @objc private func checkForUpdates(_ sender: Any?) {
        NSWorkspace.shared.open(Self.latestReleaseURL)
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

    @objc private func openReleaseWorkflow(_ sender: Any?) {
        NSWorkspace.shared.open(Self.releaseWorkflowURL)
    }

    @objc private func showThirdPartyNotices(_ sender: Any?) {
        if let noticesWindow {
            noticesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.string = Self.thirdPartyNoticesText()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Third-Party Notices"
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        noticesWindow = window
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
    }

    @objc private func togglePhoneScreen(_ sender: Any?) {
        model.togglePhoneScreenPower()
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
             #selector(zoomIn(_:))?,
             #selector(zoomOut(_:))?,
             #selector(centerMirror(_:))?:
            return model.hasActiveMirrorSession
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

    private static func thirdPartyNoticesText() -> String {
        let noticeText = textResource(
            named: "THIRD_PARTY_NOTICES",
            extension: "md",
            fallbackRelativePath: "THIRD_PARTY_NOTICES.md"
        ) ?? """
        # Third-Party Notices

        This app includes components from scrcpy, licensed under the Apache License 2.0.
        """

        let licenseText = textResource(
            named: "scrcpy-APACHE-2.0",
            extension: "txt",
            subdirectory: "LICENSES",
            fallbackRelativePath: "LICENSES/scrcpy-APACHE-2.0.txt"
        ) ?? ""

        guard !licenseText.isEmpty else { return noticeText }
        return "\(noticeText)\n\n---\n\n# Apache License 2.0 - scrcpy\n\n\(licenseText)"
    }

    private static func textResource(
        named name: String,
        extension fileExtension: String,
        subdirectory: String? = nil,
        fallbackRelativePath: String
    ) -> String? {
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(fallbackRelativePath)
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
