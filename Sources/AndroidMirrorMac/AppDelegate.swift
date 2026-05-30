import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private let model = AppModel()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rootView = RootView()
            .environmentObject(model)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AppModel.onboardingWindowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Android Mirroring"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.minSize = AppModel.onboardingWindowSize
        window.contentMinSize = AppModel.onboardingWindowSize
        window.maxSize = AppModel.onboardingWindowSize
        window.contentMaxSize = AppModel.onboardingWindowSize
        window.center()
        window.makeKeyAndOrderFront(nil)
        model.registerConnectionWindow(window)
        self.window = window

        installMainMenu()
        installKeyboardScaling()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.isMirroring
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Settings...",
                action: #selector(showSettings(_:)),
                keyEquivalent: ","
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

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
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
                title: "Zoom In",
                action: #selector(zoomIn(_:)),
                keyEquivalent: "+"
            )
        )
        viewMenu.addItem(
            NSMenuItem(
                title: "Zoom Out",
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
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    private func installKeyboardScaling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        window.title = "Android Mirroring Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
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

    @objc private func takeScreenshot(_ sender: Any?) {
        model.takeScreenshot()
    }

    @objc private func toggleScreenRecording(_ sender: Any?) {
        model.toggleScreenRecording()
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
