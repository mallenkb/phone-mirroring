import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var window: NSWindow?
    private var firstRunWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var shortcutsWindow: NSWindow?
    private var noticesWindow: NSWindow?
    private let model = AppModel()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

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
        window.title = "Android Mirroring"
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
            showFirstRunWindow()
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }

        installMainMenu()
        installKeyboardScaling()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        model.shutdown()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "Android Mirroring", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Mirroring Settings...",
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
                title: "Quit Android Mirroring",
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
        if let firstRunWindow {
            centerOnMainScreen(firstRunWindow)
            firstRunWindow.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = FirstRunOnboardingView { [weak self] in
            self?.firstRunWindow?.orderOut(nil)
            self?.firstRunWindow = nil
            if let window = self?.window {
                self?.centerOnMainScreen(window)
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

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Android Mirroring"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        centerOnMainScreen(window)
        window.makeKeyAndOrderFront(nil)
        firstRunWindow = window
    }

    private func centerOnMainScreen(_ window: NSWindow) {
        let visible = NSScreen.main?.visibleFrame
            ?? window.screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        window.setFrame(
            MirrorContentWindowController.centeredFrame(size: window.frame.size, in: visible),
            display: false,
            animate: false
        )
    }

    @objc private func scanForAndroidDevices(_ sender: Any?) {
        model.scanADBDevices()
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
        window.title = "Mirroring Settings"
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
        alert.informativeText = "This clears saved onboarding and paired-phone records, then relaunches the app into onboarding."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Onboarding")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.resetFirstTimeUserOnboardingState()
        relaunchApp()
    }

    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
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
