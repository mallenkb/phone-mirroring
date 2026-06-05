import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FigmaMirrorExperienceView()
            .environmentObject(model)
            .background(WindowRegistrationView(model: model))
    }
}

/// Registers the host window with AppModel so it can be reopened when a mirror
/// session ends. This window is always the phone/mirror window — the first-run
/// onboarding lives in its own separate window and never touches this one.
struct WindowRegistrationView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private func configure(window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        model.registerConnectionWindow(window)
        configurePhoneWindow(window, coordinator: coordinator)
    }

    private func configurePhoneWindow(_ window: NSWindow, coordinator: Coordinator) {
        window.styleMask.remove(.titled)
        window.styleMask.remove(.resizable)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        applySize(AppModel.onboardingWindowSize, to: window)
        Self.applyPhoneWindowMask(to: window)
        coordinator.installOrUpdate(parent: window, model: model)
        coordinator.setMirroring(model.isMirroring)
    }

    private func applySize(_ size: NSSize, to window: NSWindow) {
        if window.contentView?.frame.size != size {
            let visible = NSScreen.main?.visibleFrame
                ?? window.screen?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 390, height: 850)
            window.setFrame(
                MirrorContentWindowController.centeredFrame(size: size, in: visible),
                display: false,
                animate: false
            )
        }
        window.minSize = size
        window.contentMinSize = size
        window.maxSize = size
        window.contentMaxSize = size
    }

    static func applyPhoneWindowMask(to window: NSWindow) {
        let radius = MirrorContentWindowController.onboardingCornerRadius()
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = radius
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.layer?.setValue("continuous", forKey: "cornerCurve")
    }

    @MainActor
    final class Coordinator {
        private let chromeBar = MirrorChromeBar()
        private weak var parentWindow: NSWindow?
        private var toolbarWindow: NSWindow?
        private var revealMonitors: [Any] = []
        private var hideWorkItem: DispatchWorkItem?
        private var chromeVisible = false
        private var isDraggingChrome = false
        private var isPointerInTopZone = false
        private var isMirroring = false
        private let onboardingPhoneAspect: CGFloat = MirrorContentWindowController.defaultMirrorAspect
        private var onboardingReferenceHeight: CGFloat { AppModel.onboardingWindowSize.height }

        func installOrUpdate(parent: NSWindow, model: AppModel) {
            if parentWindow !== parent || toolbarWindow == nil {
                uninstall()
                install(parent: parent, model: model)
            }

            chromeBar.setDeviceName(model.selectedDevice.name)
            chromeBar.setRecording(model.isRecording)
            repositionToolbarWindow()
        }

        func setMirroring(_ mirroring: Bool) {
            guard isMirroring != mirroring else { return }
            isMirroring = mirroring
            if mirroring {
                hideChromeImmediately()
                stopRevealMonitoring()
                toolbarWindow?.orderOut(nil)
            } else {
                startRevealMonitoring()
            }
        }

        func uninstall() {
            if let toolbarWindow {
                parentWindow?.removeChildWindow(toolbarWindow)
                toolbarWindow.close()
            }
            stopRevealMonitoring()
            hideWorkItem?.cancel()
            hideWorkItem = nil
            chromeVisible = false
            isDraggingChrome = false
            isPointerInTopZone = false
            toolbarWindow = nil
            parentWindow = nil
        }

        private func install(parent: NSWindow, model: AppModel) {
            parentWindow = parent

            chromeBar.translatesAutoresizingMaskIntoConstraints = true
            chromeBar.autoresizingMask = [.width, .height]
            chromeBar.chromeHeight = MirrorContentWindowController.toolbarBarHeight
            chromeBar.configure(
                deviceName: model.selectedDevice.name,
                onHome: { model.sendAndroidKey("KEYCODE_HOME") },
                onRecentApps: { model.sendAndroidKey("KEYCODE_APP_SWITCH") },
                onScreenshot: { model.takeScreenshot() },
                onRecordingToggle: { model.toggleScreenRecording() }
            )
            chromeBar.onClose = { NSApplication.shared.terminate(nil) }
            chromeBar.onMinimize = { [weak parent] in parent?.miniaturize(nil) }
            chromeBar.onZoom = { [weak parent] in parent?.zoom(nil) }
            chromeBar.onDragMouseDown = { [weak parent] event in
                parent?.performDrag(with: event)
            }
            chromeBar.onDragStateChange = { [weak self] isDragging in
                self?.setChromeDragging(isDragging)
            }
            chromeBar.onHoverChange = { [weak self] _ in
                self?.evaluateRevealZone()
            }
            setOnboardingChromeControlsVisible(false)
            chromeBar.setBarBackgroundVisible(true, animated: false)

            let toolbar = MirrorToolbarWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: toolbarWidth(for: parent),
                    height: MirrorContentWindowController.toolbarBarHeight
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            toolbar.isOpaque = false
            toolbar.backgroundColor = .clear
            toolbar.hasShadow = true
            toolbar.level = .normal
            toolbar.ignoresMouseEvents = false
            toolbar.contentView = chromeBar
            toolbar.alphaValue = 0
            parent.addChildWindow(toolbar, ordered: .above)
            toolbarWindow = toolbar
            repositionToolbarWindow()
            if !isMirroring {
                startRevealMonitoring()
            }
        }

        private func repositionToolbarWindow() {
            guard let parentWindow, let toolbarWindow else { return }
            let frame = parentWindow.frame
            let toolbarWidth = toolbarWidth(for: parentWindow)
            var originY = frame.maxY + MirrorContentWindowController.toolbarGap
            if let visible = parentWindow.screen?.visibleFrame,
               originY + MirrorContentWindowController.toolbarBarHeight > visible.maxY {
                originY = frame.maxY - MirrorContentWindowController.toolbarBarHeight
            }
            toolbarWindow.setFrame(
                NSRect(
                    x: frame.midX - toolbarWidth / 2,
                    y: originY,
                    width: toolbarWidth,
                    height: MirrorContentWindowController.toolbarBarHeight
                ),
                display: true
            )
        }

        private func toolbarWidth(for window: NSWindow) -> CGFloat {
            let referenceWidth = onboardingReferenceHeight * onboardingPhoneAspect
            let contentSize = window.contentView?.bounds.size ?? window.frame.size
            let scale = max(
                0.1,
                min(contentSize.width / referenceWidth, contentSize.height / onboardingReferenceHeight)
            )
            return referenceWidth * scale
        }

        private func startRevealMonitoring() {
            guard revealMonitors.isEmpty else { return }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
                self?.evaluateRevealZone()
                return event
            }) {
                revealMonitors.append(local)
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
                self?.evaluateRevealZone()
            }) {
                revealMonitors.append(global)
            }
        }

        private func stopRevealMonitoring() {
            for monitor in revealMonitors {
                NSEvent.removeMonitor(monitor)
            }
            revealMonitors.removeAll()
        }

        private func revealZoneContains(_ point: NSPoint) -> Bool {
            guard let parentWindow, let toolbarWindow else { return false }
            let toolbarWidth = toolbarWidth(for: parentWindow)
            let phoneMinX = parentWindow.frame.midX - toolbarWidth / 2
            let zone = NSRect(
                x: phoneMinX,
                y: parentWindow.frame.maxY,
                width: toolbarWidth,
                height: MirrorContentWindowController.toolbarGap
                    + MirrorContentWindowController.toolbarBarHeight
                    + MirrorContentWindowController.toolbarRevealSlop
            )
            return zone.contains(point) || toolbarWindow.frame.contains(point)
        }

        private func evaluateRevealZone() {
            guard !isMirroring else {
                hideChromeImmediately()
                return
            }
            if revealZoneContains(NSEvent.mouseLocation) {
                isPointerInTopZone = true
                hideWorkItem?.cancel()
                setChromeVisible(true)
            } else {
                isPointerInTopZone = false
                scheduleHide()
            }
        }

        private func scheduleHide() {
            guard !isDraggingChrome, !isPointerInTopZone else {
                isPointerInTopZone = true
                return
            }
            hideWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isDraggingChrome else { return }
                if self.isPointerInTopZone {
                    self.isPointerInTopZone = true
                    return
                }
                self.setChromeVisible(false)
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + MirrorContentWindowController.chromeHideDelay,
                execute: workItem
            )
        }

        private func setChromeVisible(_ visible: Bool) {
            guard !isMirroring || !visible else { return }
            guard chromeVisible != visible else { return }
            chromeVisible = visible
            guard let toolbarWindow else { return }

            if visible {
                repositionToolbarWindow()
                setOnboardingChromeControlsVisible(true)
                toolbarWindow.orderFront(nil)
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = visible ? MirrorChromeBar.barRevealDuration : MirrorChromeBar.barHideDuration
                context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
                toolbarWindow.animator().alphaValue = visible ? 1 : 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.chromeVisible {
                        self.setOnboardingChromeControlsVisible(false)
                    }
                }
            }
        }

        private func hideChromeImmediately() {
            hideWorkItem?.cancel()
            chromeVisible = false
            isPointerInTopZone = false
            toolbarWindow?.alphaValue = 0
            setOnboardingChromeControlsVisible(false)
        }

        private func setOnboardingChromeControlsVisible(_ visible: Bool) {
            chromeBar.setControlsVisible(visible)
            chromeBar.setTrailingActionsVisible(false)
        }

        private func setChromeDragging(_ isDragging: Bool) {
            isDraggingChrome = isDragging
            if isDragging {
                hideWorkItem?.cancel()
                setChromeVisible(true)
            } else {
                evaluateRevealZone()
            }
        }
    }
}
