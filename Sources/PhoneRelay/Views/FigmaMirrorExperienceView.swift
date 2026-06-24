import AppKit
import Combine
import CoreImage
import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    private enum ConnectionStep {
        case chooseMethod
        case wirelessPairing
    }

    private enum WirelessSheet {
        case wifiOnly
        case wirelessDebugging
    }

    @EnvironmentObject private var model: AppModel
    @State private var connectionStep: ConnectionStep = .chooseMethod
    /// The row the user tapped from the chooser. While set, the chooser stays
    /// visible and that row owns the spinner instead of showing a full loading
    /// surface with transport-specific copy.
    @State private var inlineConnectingTransport: AppModel.ConnectionLoadingTransport?
    @State private var usbAvailabilityBeforeConnect = false
    @State private var wifiAvailabilityBeforeConnect = false
    @State private var showsConnectionHelpSheet = false
    @State private var isConnectionHelpSheetPresented = false
    @State private var activeWirelessSheet: WirelessSheet?
    @State private var isWirelessDebuggingSheetContentVisible = false
    private let phoneAspect: CGFloat = MirrorContentWindowController.defaultMirrorAspect
    private let edgeBleed: CGFloat = 2
    private var referenceHeight: CGFloat { AppModel.onboardingWindowSize.height }
    private var referenceWidth: CGFloat { referenceHeight * phoneAspect }
    /// Drawn straight from the model's single connection-status source so the USB
    /// button's loader and the device pill below it can never disagree.
    private var isConnecting: Bool {
        model.isActivelyConnecting || model.isMirroring
    }
    private var isUSBButtonBusy: Bool {
        inlineConnectingTransport == .usb
    }
    private var isWirelessButtonBusy: Bool {
        inlineConnectingTransport == .wifi
    }
    private var isChooserButtonDisabled: Bool {
        inlineConnectingTransport != nil
    }
    private var effectiveUSBConnectionAvailable: Bool {
        inlineConnectingTransport == nil
            ? model.isUSBConnectionAvailable || isCurrentUSBSessionOnline
            : usbAvailabilityBeforeConnect
    }
    private var effectiveWiFiConnectionAvailable: Bool {
        inlineConnectingTransport == nil
            ? model.isWirelessConnectionAvailable || isCurrentWiFiSessionOnline
            : wifiAvailabilityBeforeConnect
    }
    private var isCurrentUSBSessionOnline: Bool {
        guard model.isMirroring || model.isSelectedDeviceOnline else { return false }
        guard let serial = model.selectedDevice.adbSerial,
              !serial.isEmpty else {
            return model.selectedDevice.network.localizedCaseInsensitiveContains("usb")
        }
        return (model.isMirroring || model.isSelectedDeviceOnline)
            && (!AppModel.isWirelessADBTarget(serial)
                || model.selectedDevice.network.localizedCaseInsensitiveContains("usb"))
    }
    private var isCurrentWiFiSessionOnline: Bool {
        guard model.isMirroring || model.isSelectedDeviceOnline else { return false }
        let network = model.selectedDevice.network
        let networkIsWireless = network.localizedCaseInsensitiveContains("wi-fi")
            || network.localizedCaseInsensitiveContains("wireless")
        guard let serial = model.selectedDevice.adbSerial,
              !serial.isEmpty else { return networkIsWireless }
        return (model.isMirroring || model.isSelectedDeviceOnline)
            && (AppModel.isWirelessADBTarget(serial)
                || networkIsWireless)
    }
    private let maxColumnWidth: CGFloat = 620
    private let qrPanelSize: CGFloat = 236.42318725585938
    private let accent = onboardingAccentCyan
    /// Secondary/cyan/400 — the enabled "Connect" button fill in the design.
    private let cyan400 = Color(red: 34.0 / 255.0, green: 211.0 / 255.0, blue: 238.0 / 255.0)
    private let qrRefreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private let errorPillDuration: UInt64 = 5_000_000_000

    var body: some View {
        ZStack {
            Color.clear

            designSurface
                .frame(
                    width: referenceWidth - edgeBleed * 2,
                    height: referenceHeight - edgeBleed * 2
                )
        }
            .frame(width: referenceWidth, height: referenceHeight)
            .fixedSize()
        .onAppear {
            syncPreferredConnectionStep()
        }
        .onChange(of: model.connectionWindowPrefersWirelessDetails) { _ in
            syncPreferredConnectionStep()
        }
        .onChange(of: model.connectionWindowNavigationResetID) { _ in
            syncPreferredConnectionStep()
        }
        .onReceive(qrRefreshTimer) { _ in
            guard activeWirelessSheet == .wirelessDebugging || connectionStep == .wirelessPairing,
                  !isConnecting
            else { return }
            model.restartQRCodePairingSession()
        }
        .onDisappear {
            model.stopQRCodePairingSession()
        }
        .onChange(of: model.isActivelyConnecting) { connecting in
            // The row attempt has resolved (mirroring started, or it failed and
            // returned to idle) — drop back to the normal loading-surface rules.
            if !connecting { inlineConnectingTransport = nil }
        }
    }

    @ViewBuilder
    private var designSurface: some View {
        FigmaPhoneFrame {
            onboardingContent
        }
    }

    private var onboardingContent: some View {
        GeometryReader { proxy in
            let scale = min(1, max(0.5, min(proxy.size.height / 695.2727, proxy.size.width / 320)))
            let contentWidth = min(proxy.size.width - 32 * scale, maxColumnWidth)

            ZStack {
                if connectionStep == .chooseMethod {
                    VStack(spacing: 0) {
                        connectionChoiceScreen(width: contentWidth, scale: scale)
                            .frame(width: contentWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: contentWidth)
                    .padding(.top, 24 * scale)
                    .padding(.bottom, 66 * scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
                } else {
                    ZStack(alignment: .topLeading) {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 23.273 * scale) {
                                wirelessPairingScreen(width: contentWidth, scale: scale)
                                    .frame(width: contentWidth)
                            }
                            .frame(width: contentWidth)
                            .padding(.top, 92 * scale)
                            .padding(.bottom, 66 * scale)
                            .frame(width: proxy.size.width)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)

                        fixedWirelessBackButton(width: contentWidth, scale: scale)
                            .padding(.top, 24 * scale)
                            .frame(width: proxy.size.width, alignment: .center)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
                }

                VStack {
                    Spacer()
                    bottomStatusPill(width: contentWidth, scale: scale)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        .padding(.bottom, 16 * scale)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
            }
            .clipped()
            .animation(.smooth(duration: 0.38, extraBounce: 0.04), value: connectionStep)
            .overlay {
                if showsConnectionHelpSheet {
                    connectionHelpOverlay(scale: scale)
                } else if let activeWirelessSheet {
                    wirelessSheetOverlay(activeWirelessSheet, width: contentWidth, scale: scale)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showsConnectionHelpSheet)
            .animation(.easeOut(duration: 0.2), value: activeWirelessSheet != nil)
            .task(id: model.activeError?.id) {
                guard let error = model.activeError else { return }
                do {
                    try await Task.sleep(nanoseconds: errorPillDuration)
                    guard !Task.isCancelled, model.activeError?.id == error.id else { return }
                    model.dismissError()
                } catch {
                    return
                }
            }
        }
    }

    private func connectionChoiceScreen(width: CGFloat, scale: CGFloat) -> some View {
        // "Message and description" — centered as a group in the available
        // space (Figma: flex-1, gap 48 between header and the option rows).
        VStack(spacing: 48 * scale) {
            VStack(spacing: 11.636 * scale) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 33 * scale, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(width: 61 * scale, height: 40 * scale)

                Text(model.isFirstTimeUSBSetup ? "Set up your Android phone with USB" : "Connect your Android phone")
                    .font(.system(size: 16 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: width)
            }

            VStack(spacing: 18 * scale) {
                VStack(spacing: 4 * scale) {
                    connectionChoiceRow(
                        iconName: "cable.connector",
                        resourceIconName: "usb-cable",
                        title: "Connect with USB",
                        subtitle: model.isFirstTimeUSBSetup ? "Plug in once to authorize Wi-Fi mirroring." : "Cable connection.",
                        showsProgress: isUSBButtonBusy,
                        isDisabled: isChooserButtonDisabled,
                        isAvailable: effectiveUSBConnectionAvailable,
                        width: width,
                        scale: scale,
                        action: {
                            usbAvailabilityBeforeConnect = model.isUSBConnectionAvailable
                            wifiAvailabilityBeforeConnect = model.isWirelessConnectionAvailable
                            inlineConnectingTransport = .usb
                            model.connectViaUSB()
                        }
                    )

                    if !model.isFirstTimeUSBSetup {
                        connectionChoiceRow(
                            iconName: "wifi",
                            title: "Connect with Wi-Fi IP",
                            subtitle: "No cable. Enter the phone Wi-Fi IP address.",
                            showsProgress: isWirelessButtonBusy,
                            isDisabled: isChooserButtonDisabled,
                            isAvailable: effectiveWiFiConnectionAvailable,
                            width: width,
                            scale: scale,
                            action: {
                                usbAvailabilityBeforeConnect = model.isUSBConnectionAvailable
                                wifiAvailabilityBeforeConnect = model.isWirelessConnectionAvailable
                                if model.hasVisibleSavedWirelessConnection {
                                    inlineConnectingTransport = .wifi
                                    model.reconnectOverWiFi(inlineUntilConnected: true)
                                } else if AppModel.normalizedManualADBTarget(model.manualADBTarget) != nil {
                                    inlineConnectingTransport = .wifi
                                    model.connectManualADBTarget()
                                } else {
                                    navigate(to: .wirelessPairing)
                                    model.ensureQRCodePairingSession()
                                }
                            }
                        )
                    }
                }

                VStack(spacing: 8 * scale) {
                    Button(action: showConnectionHelpSheet) {
                        Text("Can't connect?")
                            .font(.system(size: 14 * scale, weight: .regular))
                            .foregroundStyle(accent)
                            .underline()
                            .frame(height: 28 * scale)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: openDeviceSettings) {
                        Text("Manage Devices")
                            .font(.system(size: 14 * scale, weight: .regular))
                            .foregroundStyle(accent)
                            .underline()
                            .frame(height: 28 * scale)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: width)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wirelessPairingScreen(width: CGFloat, scale: CGFloat) -> some View {
        VStack(spacing: 23.273 * scale) {
            // "Message and description" — centered as a group. WiFi Only is the
            // first wireless path; Wireless Debugging QR pairing is the fallback
            // when no legacy Wi-Fi adb listener is available yet.
            VStack(spacing: 16 * scale) {
                VStack(spacing: 11.636 * scale) {
                    Image(systemName: "wifi")
                        .font(.system(size: 28 * scale, weight: .regular))
                        .foregroundStyle(accent)
                        .frame(width: 41 * scale, height: 40 * scale)

                    VStack(spacing: 8 * scale) {
                        VStack(spacing: 2 * scale) {
                            Text("Connect with Wi-Fi IP Only")
                                .font(.system(size: 14 * scale, weight: .bold))
                                .foregroundStyle(.white)

                            Text("No cable. Enter Wi-Fi IP or scan QR for Wireless Debugging.")
                                .font(.system(size: 12 * scale, weight: .regular))
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .frame(width: width)
                        }
                    }
                }

                manualADBTargetRow(width: width - 32 * scale, scale: scale)

                Text("or")
                    .font(.system(size: 12 * scale, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: width)

                wirelessDebuggingQRCodeSection(width: width, scale: scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fixedWirelessBackButton(width: CGFloat, scale: CGFloat) -> some View {
        HStack {
            iconButton(systemName: "arrow.left", scale: scale) {
                navigate(to: .chooseMethod)
            }
            Spacer()
        }
        .frame(width: width)
    }

    private func navigate(to step: ConnectionStep) {
        if step == .chooseMethod {
            model.clearConnectionWindowPreferredStep()
        }
        withAnimation(.smooth(duration: 0.34, extraBounce: 0.05)) {
            connectionStep = step
        }
    }

    private func syncPreferredConnectionStep() {
        if model.connectionWindowPrefersWirelessDetails {
            connectionStep = .wirelessPairing
            model.ensureQRCodePairingSession()
        } else {
            connectionStep = .chooseMethod
            model.stopQRCodePairingSession()
        }
    }

    private func openDeveloperOptionsHelp() {
        guard let url = URL(string: "https://developer.android.com/studio/debug/dev-options") else { return }
        NSWorkspace.shared.open(url)
    }

    private func wirelessDebuggingQRCodeSection(width: CGFloat, scale: CGFloat) -> some View {
        let sheetPadding = 16 * scale
        let panelSize = min(qrPanelSize * scale, width - sheetPadding * 2)
        return VStack(spacing: 12 * scale) {
            VStack(spacing: 4 * scale) {
                Text("Wireless Debugging (scan QR)")
                    .font(.system(size: 14 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("On your phone: Settings → Developer options → Wireless debugging → Pair device with QR code.")
                    .font(.system(size: 12 * scale, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            qrPairingPanel(panelSize: panelSize, codeSize: panelSize * 0.8985)

            Button(action: openDeveloperOptionsHelp) {
                Text("Need help finding developer options?")
                    .font(.system(size: 12 * scale, weight: .regular))
                    .foregroundStyle(accent)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, sheetPadding)
        .padding(.top, 4 * scale)
        .padding(.bottom, 16 * scale)
        .frame(width: width)
    }

    private func connectionChoiceRow(
        iconName: String,
        resourceIconName: String? = nil,
        title: String,
        subtitle: String,
        showsProgress: Bool,
        isDisabled: Bool,
        isAvailable: Bool,
        width: CGFloat,
        scale: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard !isDisabled else { return }
            action()
        }) {
            HStack(spacing: 8.727 * scale) {
                connectionChoiceIcon(
                    systemName: iconName,
                    resourceName: resourceIconName,
                    isAvailable: isAvailable || showsProgress,
                    scale: scale
                )
                .frame(width: 32 * scale, height: 32 * scale)

                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(title)
                        .font(.system(size: 14 * scale, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(subtitle)
                        .font(.system(size: 12 * scale, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                // Right-hand affordance: a spinner while this row's action is in
                // flight, otherwise the chevron.
                ZStack {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .scaleEffect(max(0.7, 0.85 * scale))
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13 * scale, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 17.455 * scale, height: 17.455 * scale)
            }
            .padding(8 * scale)
            .frame(minHeight: 62 * scale)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func connectionChoiceIcon(
        systemName: String,
        resourceName: String?,
        isAvailable: Bool,
        scale: CGFloat
    ) -> some View {
        if let resourceName,
           let image = Self.resourceImage(named: resourceName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(isAvailable ? Self.connectionOnlineGreen : .white)
                .frame(width: 22 * scale, height: 24 * scale)
        } else {
            Image(systemName: systemName)
                .font(.system(size: 16 * scale, weight: .regular))
                .foregroundStyle(isAvailable ? Self.connectionOnlineGreen : .white)
        }
    }

    private static func resourceImage(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func showWirelessSheet(_ sheet: WirelessSheet) {
        if sheet == .wirelessDebugging {
            isWirelessDebuggingSheetContentVisible = false
        }
        withAnimation(.smooth(duration: 0.28, extraBounce: 0.02)) {
            activeWirelessSheet = sheet
        }
        if sheet == .wirelessDebugging {
            model.ensureQRCodePairingSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard activeWirelessSheet == .wirelessDebugging else { return }
                withAnimation(.smooth(duration: 0.28, extraBounce: 0.02)) {
                    isWirelessDebuggingSheetContentVisible = true
                }
            }
        }
    }

    private func dismissWirelessSheet() {
        withAnimation(.smooth(duration: 0.24, extraBounce: 0.02)) {
            activeWirelessSheet = nil
            isWirelessDebuggingSheetContentVisible = false
        }
        model.stopQRCodePairingSession()
    }

    private func wirelessSheetOverlay(_ sheet: WirelessSheet, width: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.24)
                .onTapGesture {
                    dismissWirelessSheet()
                }
                .transition(.opacity)

            switch sheet {
            case .wifiOnly:
                wifiOnlySheet(width: width, scale: scale)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .wirelessDebugging:
                wirelessDebuggingSheet(width: width, scale: scale)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func wifiOnlySheet(width: CGFloat, scale: CGFloat) -> some View {
        bottomSheetChrome(scale: scale) {
            VStack(alignment: .leading, spacing: 20 * scale) {
                bottomSheetHeader(
                    title: "Connect via Wi-Fi only",
                    subtitle: "Enter the phone Wi-Fi IP address only.",
                    scale: scale
                )

                manualADBTargetRow(width: width, scale: scale)

                Button {
                    showWirelessSheet(.wirelessDebugging)
                } label: {
                    HStack(spacing: 12 * scale) {
                        connectionChoiceIcon(
                            systemName: "qrcode.viewfinder",
                            resourceName: nil,
                            isAvailable: effectiveWiFiConnectionAvailable,
                            scale: scale
                        )
                        .frame(width: 32 * scale, height: 32 * scale)

                        VStack(alignment: .leading, spacing: 2 * scale) {
                            Text("Connect via Wireless Debugging")
                                .font(.system(size: 14 * scale, weight: .regular))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text("More reliable WiFi connection. Pair with QR code.")
                                .font(.system(size: 12 * scale, weight: .regular))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13 * scale, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(8 * scale)
                    .frame(minHeight: 62 * scale)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func wirelessDebuggingSheet(width: CGFloat, scale: CGFloat) -> some View {
        let sheetPadding = 16 * scale
        let panelSize = min(qrPanelSize * scale, width - sheetPadding * 2)
        return bottomSheetChrome(scale: scale) {
            VStack(spacing: 14 * scale) {
                bottomSheetHeader(
                    title: "Connect via Wireless Debugging",
                    subtitle: "Open Settings → Developer options → Wireless debugging, tap Pair device with QR code, then scan the QR code below.",
                    scale: scale
                )

                Button(action: openDeveloperOptionsHelp) {
                    Text("Need help finding developer options?")
                        .font(.system(size: 12 * scale, weight: .regular))
                        .foregroundStyle(accent)
                        .underline()
                }
                .buttonStyle(.plain)

                qrPairingPanel(panelSize: panelSize, codeSize: panelSize * 0.8985)
            }
            .opacity(isWirelessDebuggingSheetContentVisible ? 1 : 0)
            .offset(y: isWirelessDebuggingSheetContentVisible ? 0 : 12 * scale)
            .scaleEffect(isWirelessDebuggingSheetContentVisible ? 1 : 0.985, anchor: .top)
        }
    }

    private func bottomSheetChrome<Content: View>(
        scale: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20 * scale) {
            VStack(alignment: .center, spacing: 8 * scale) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 65 * scale, height: 6.4 * scale)
            }
            .frame(maxWidth: .infinity)

            content()
        }
        .padding(.horizontal, 16 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 24 * scale)
        .background(
            TopRoundedRectangle(radius: 28 * scale)
                .fill(onboardingDeepCyan)
                .overlay(
                    TopRoundedRectangle(radius: 28 * scale)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 0)
        .padding(.bottom, 0)
    }

    private func bottomSheetHeader(title: String, subtitle: String, scale: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 6 * scale) {
            Text(title)
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 14 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func showConnectionHelpSheet() {
        showsConnectionHelpSheet = true
        isConnectionHelpSheetPresented = false
        Task { @MainActor in
            await Task.yield()
            guard showsConnectionHelpSheet else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                isConnectionHelpSheetPresented = true
            }
        }
    }

    private func openDeviceSettings() {
        NSApp.sendAction(Selector(("showSettings:")), to: nil, from: nil)
    }

    private func dismissConnectionHelpSheet() {
        withAnimation(.easeIn(duration: 0.22)) {
            isConnectionHelpSheetPresented = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if !isConnectionHelpSheetPresented {
                showsConnectionHelpSheet = false
            }
        }
    }

    private func connectionHelpOverlay(scale: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(isConnectionHelpSheetPresented ? 0.24 : 0)
                .onTapGesture {
                    dismissConnectionHelpSheet()
                }
                .animation(.easeInOut(duration: 0.22), value: isConnectionHelpSheetPresented)

            connectionHelpSheet(scale: scale)
                .offset(y: isConnectionHelpSheetPresented ? 0 : referenceHeight * scale)
                .animation(.easeOut(duration: 0.3), value: isConnectionHelpSheetPresented)
        }
    }

    private func connectionHelpSheet(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20 * scale) {
            VStack(alignment: .center, spacing: 8 * scale) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 65 * scale, height: 6.4 * scale)

                VStack(alignment: .center, spacing: 6 * scale) {
                    Text("Can't connect?")
                        .font(.system(size: 18 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Check the setup for each connection method.")
                        .font(.system(size: 14 * scale, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16 * scale) {
                connectionHelpStep(
                    number: 1,
                    text: stepText(
                        lead: "USB debugging:",
                        body: " open Settings → Developer options, turn on USB debugging, reconnect the cable, then tap ",
                        emphasis: "Allow",
                        suffix: " on your phone.",
                        scale: scale
                    ),
                    scale: scale
                )
                connectionHelpStep(
                    number: 2,
                    text: stepText(
                        lead: "Wi‑Fi IP only:",
                        body: " open your phone’s Wi‑Fi details or Advanced settings, find the IP address, then enter it here.",
                        emphasis: nil,
                        suffix: "",
                        scale: scale
                    ),
                    scale: scale
                )
                connectionHelpStep(
                    number: 3,
                    text: stepText(
                        lead: "Wireless debugging QR:",
                        body: " open Developer options → Wireless debugging, tap Pair device with QR code, then scan the QR code.",
                        emphasis: nil,
                        suffix: "",
                        scale: scale
                    ),
                    scale: scale
                )
                connectionHelpStep(
                    number: 4,
                    text: stepText(
                        lead: "Still stuck:",
                        body: " reseat the cable, restart the desktop app, then try connecting again.",
                        emphasis: nil,
                        suffix: "",
                        scale: scale
                    ),
                    scale: scale
                )
            }

            Button(action: dismissConnectionHelpSheet) {
                Text("Close")
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 2 * scale)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 24 * scale)
        .background(
            TopRoundedRectangle(radius: 28 * scale)
                .fill(onboardingDeepCyan)
                .overlay(
                    TopRoundedRectangle(radius: 28 * scale)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 0)
        .padding(.bottom, 0)
    }

    private func connectionHelpStep(number: Int, text: Text, scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
            Text("\(number)")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24 * scale, height: 24 * scale)
                .background(Circle().fill(Color.white.opacity(0.1)))

            text
                .font(.system(size: 14 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.68))
                .lineSpacing(1.5 * scale)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepText(
        lead: String,
        body: String,
        emphasis: String?,
        suffix: String,
        scale: CGFloat
    ) -> Text {
        var text = Text(lead).fontWeight(.bold) + Text(body)
        if let emphasis {
            text = text + Text(emphasis).fontWeight(.bold)
        }
        return text + Text(suffix)
    }

    private func iconButton(systemName: String, scale: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                Image(systemName: systemName)
                    .font(.system(size: 16 * scale, weight: .regular))
                    .foregroundStyle(.white)
            }
            .frame(width: 40 * scale, height: 40 * scale)
        }
        .buttonStyle(.plain)
    }

    private func bottomStatusPill(width: CGFloat, scale: CGFloat) -> some View {
        let state = model.connectionPillState
        let isConnecting = state == .connecting || state == .reconnecting
        let statusText = isConnecting ? "Connecting to" : model.connectionPillText
        let deviceLabel = state == .noPhone ? "" : model.connectionDeviceLabel
        let visibleDeviceLabel = isConnecting && !deviceLabel.isEmpty ? "\(deviceLabel)..." : deviceLabel
        let fontSize = 12 * scale

        return HStack(spacing: 4 * scale) {
            StatusDot(color: Self.pillDotColor(for: state), diameter: 8 * scale, pulses: isConnecting)

            Text(statusText)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize()

            if !visibleDeviceLabel.isEmpty {
                Text(visibleDeviceLabel)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 8 * scale)
        .frame(height: 26 * scale)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .frame(maxWidth: width, alignment: .center)
    }

    /// Status dot tint per pill state: grey when idle/offline, amber while
    /// connecting/reconnecting, green online, red on failure.
    private static let connectionOnlineGreen = Color(red: 0.29, green: 0.87, blue: 0.50)

    private static func pillDotColor(for state: AppModel.ConnectionPillState) -> Color {
        switch state {
        case .noPhone, .offline:
            return Color.white.opacity(0.45)
        case .actionNeeded:
            return Color(red: 0.97, green: 0.44, blue: 0.44)
        case .connecting, .reconnecting:
            return Color(red: 0.98, green: 0.75, blue: 0.18)
        case .online:
            return connectionOnlineGreen
        case .failed:
            return Color(red: 0.97, green: 0.44, blue: 0.44)
        }
    }

    private func manualADBTargetRow(width: CGFloat, scale: CGFloat) -> some View {
        let isConnecting = model.isManualADBTargetConnecting
        let connectEnabled = !model.isActivelyConnecting
            && AppModel.normalizedManualADBTarget(model.manualADBTarget) != nil

        return VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(spacing: 8.727 * scale) {
                TextField("e.g. 192.168.1.23", text: $model.manualADBTarget)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14 * scale, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .onSubmit {
                        model.connectManualADBTarget()
                    }

                Button(action: model.connectManualADBTarget) {
                    HStack(spacing: 8 * scale) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(onboardingDeepCyan)
                                .scaleEffect(max(0.7, 0.82 * scale))
                        }

                        Text(isConnecting ? "Connecting" : "Connect")
                            .font(.system(size: 14 * scale, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(connectEnabled || isConnecting ? onboardingDeepCyan : Color.white.opacity(0.5))
                    .padding(.horizontal, 12 * scale)
                    .frame(minWidth: (isConnecting ? 106 : 82) * scale)
                    .frame(height: 40 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                            .fill(connectEnabled || isConnecting ? cyan400 : Color.white.opacity(0.2))
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .buttonStyle(.plain)
                .disabled(!connectEnabled || isConnecting)
            }
            .padding(.leading, 16 * scale)
            .padding(.trailing, 4 * scale)
            .padding(.vertical, 4 * scale)
            .frame(maxWidth: .infinity)
            .frame(height: 48 * scale)
            .background(
                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )

        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func qrPairingPanel(panelSize: CGFloat, codeSize: CGFloat) -> some View {
        let radius = 18.472 * (panelSize / qrPanelSize)
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.22), radius: 14 * (panelSize / qrPanelSize), x: 0, y: 8)

            if let payload = model.qrPairingSession?.payload,
               let image = qrImage(from: payload, size: codeSize) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: codeSize, height: codeSize)
                    .accessibilityLabel("ADB wireless pairing QR code")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: panelSize, height: panelSize)
    }

    private func qrImage(from payload: String, size: CGFloat) -> NSImage? {
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent.integral
        let scale = size / max(extent.width, extent.height)
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

}

struct FigmaPhoneFrame<Content: View>: View {
    @ViewBuilder var content: Content
    private var cornerRadius: CGFloat {
        MirrorContentWindowController.onboardingCornerRadius()
    }
    private var frameShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            onboardingDeepCyan
                .overlay(
                    frameShape
                        .inset(by: 0.5)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )

            content
        }
        .clipShape(frameShape)
    }
}

private struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(radius, rect.width / 2, rect.height / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Standalone first-run onboarding, hosted in its own content-sized window that
/// is completely separate from the connection/mirror window — so its sizing and
/// chrome can never affect the mirror frame. The view sizes to its own content
/// (fixed width, intrinsic height, real bottom padding) so the host window can
/// wrap it. It dismisses itself via `onDismiss` when the user proceeds or as
/// soon as a live device (USB or wireless) appears.
///
/// The flow has two steps: a welcome step explaining how to connect, then a
/// permissions step. Both step surfaces stay mounted so the host window's
/// one-shot `fittingSize` covers the taller step and never changes while
/// paging.
///
/// Styled as a borderless rounded card: a full-bleed gradient hero banner on
/// top (artwork crossfades per step), then a flat panel with a left-aligned
/// title, subtitle, rows, and capsule buttons pinned to the bottom corners.
struct FirstRunOnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case permissions
    }

    @EnvironmentObject private var model: AppModel
    @AppStorage("hasSeenFirstTimeUserOnboarding") private var hasSeen = false
    @State private var step: Step
    @State private var hasAutoRequestedLocalNetwork = false
    let onDismiss: () -> Void

    private let panelWidth: CGFloat = 660
    private let panelPadding: CGFloat = 44
    private let heroHeight: CGFloat = 250
    private let panelCornerRadius: CGFloat = 22
    private var innerWidth: CGFloat { panelWidth - panelPadding * 2 }
    private let stepAnimation = Animation.easeInOut(duration: 0.28)

    init(initialStep: Step = .welcome, onDismiss: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onDismiss = onDismiss
    }

    private var isEffectiveDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var canContinue: Bool {
        AppModel.canCompleteFirstRunOnboarding(
            hasLocalNetworkPermission: model.localNetworkPermissionGrantedForOnboarding,
            hasNotificationPermission: model.notificationPermissionGrantedForOnboarding
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            heroBanner

            ZStack(alignment: .topLeading) {
                stepSurface(welcomeContent, isActive: step == .welcome, hiddenOffset: -28)
                stepSurface(permissionsContent, isActive: step == .permissions, hiddenOffset: 28)
            }
            .padding(.horizontal, panelPadding)
            .padding(.top, 28)
            .animation(stepAnimation, value: step)

            footerButtons
                .padding(.horizontal, panelPadding)
                .padding(.top, 26)
                .padding(.bottom, 30)
        }
        .frame(width: panelWidth)
        .background(panelColor)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            QuitDotButton()
                .padding(18)
        }
        .onAppear {
            if hasSeen { onDismiss() }
        }
        .onChange(of: hasSeen) { seen in
            if seen { onDismiss() }
        }
        .onChange(of: step) { newStep in
            guard newStep == .permissions, !hasAutoRequestedLocalNetwork else { return }
            hasAutoRequestedLocalNetwork = true
            // Fire the system prompt as the permission step lands so the dialog
            // arrives with its on-screen explanation; the row's Allow button
            // remains the manual retry path.
            if !model.localNetworkPermissionGrantedForOnboarding {
                model.requestLocalNetworkPermissionFromOnboarding()
            }
        }
    }

    // MARK: - Hero banner

    private var heroBanner: some View {
        ZStack {
            LinearGradient(
                colors: heroGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            heroStreaks

            tiltedPhoneSheet
                .opacity(step == .welcome ? 1 : 0)

            appIconBadge
                .opacity(step == .welcome ? 1 : 0)

            permissionBadges
                .opacity(step == .permissions ? 1 : 0)
        }
        .frame(width: panelWidth, height: heroHeight)
        .clipped()
        .animation(stepAnimation, value: step)
        .accessibilityHidden(true)
    }

    private var heroGradientColors: [Color] {
        isEffectiveDarkMode
            ? [Color(red: 0.10, green: 0.34, blue: 0.43), Color(red: 0.05, green: 0.18, blue: 0.24)]
            : [Color(red: 0.38, green: 0.71, blue: 0.83), onboardingDeepCyan]
    }

    /// Soft diagonal light bands over the gradient, echoing the brushed-sky
    /// look of the reference design.
    private var heroStreaks: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isEffectiveDarkMode ? 0.10 : 0.30))
                .frame(width: 620, height: 110)
                .rotationEffect(.degrees(-22))
                .offset(x: -120, y: -52)
                .blur(radius: 38)

            Capsule(style: .continuous)
                .fill(Color.white.opacity(isEffectiveDarkMode ? 0.07 : 0.20))
                .frame(width: 640, height: 120)
                .rotationEffect(.degrees(-22))
                .offset(x: 210, y: 64)
                .blur(radius: 46)
        }
    }

    /// A pale phone mockup tilted into the lower-left corner of the hero, the
    /// way the reference tilts its browser-tab sheet.
    private var tiltedPhoneSheet: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(sheetColor)
            .frame(width: 250, height: 500)
            .overlay(alignment: .top) {
                VStack(spacing: 18) {
                    Circle()
                        .fill(Color.black.opacity(0.10))
                        .frame(width: 11, height: 11)
                        .padding(.top, 18)

                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.07))
                        .frame(width: 150, height: 13)
                }
            }
            .rotationEffect(.degrees(-17))
            .offset(x: -235, y: 215)
            .shadow(color: Color.black.opacity(0.18), radius: 22, x: 6, y: -2)
    }

    private var sheetColor: Color {
        isEffectiveDarkMode
            ? Color(red: 0.82, green: 0.88, blue: 0.91)
            : Color(red: 0.93, green: 0.96, blue: 0.98)
    }

    private var appIconBadge: some View {
        AppIconHeroImage()
            .frame(width: 116, height: 116)
            .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 10)
    }

    /// Overlapping circular badges for the permissions step, standing in for
    /// the reference design's joined-stats medallions.
    private var permissionBadges: some View {
        HStack(spacing: -18) {
            heroPermissionCircle(icon: "network", size: 106)
            heroPermissionCircle(icon: "iphone.gen3.radiowaves.left.and.right", size: 132)
                .zIndex(1)
            heroPermissionCircle(icon: "bell.badge", size: 106)
        }
    }

    private func heroPermissionCircle(icon: String, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.87, green: 0.93, blue: 0.97).opacity(isEffectiveDarkMode ? 0.92 : 0.95))
            Image(systemName: icon)
                .font(.system(size: size * 0.32, weight: .regular))
                .foregroundStyle(onboardingDeepCyan.opacity(0.6))
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 7)
    }

    private func stepSurface(_ content: some View, isActive: Bool, hiddenOffset: CGFloat) -> some View {
        content
            .opacity(isActive ? 1 : 0)
            .offset(x: isActive ? 0 : hiddenOffset)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle("Mirror your Android on this Mac")
            stepSubtitle("Connect with USB or scan a QR code to pair wirelessly.")

            VStack(alignment: .leading, spacing: 16) {
                setupRow(
                    icon: "cable.connector",
                    title: "USB",
                    detail: "Plug in your phone and allow USB debugging."
                )

                setupRow(
                    icon: "qrcode.viewfinder",
                    title: "Wireless",
                    detail: "Scan a QR code from your phone's Wireless debugging settings."
                )

                setupRow(
                    icon: "wifi",
                    title: "Keep devices nearby",
                    detail: "For wireless pairing, keep your phone and Mac on the same Wi-Fi network."
                )
            }
            .padding(.top, 24)
        }
        .frame(width: innerWidth, alignment: .leading)
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle("Permissions for a better experience")
            stepSubtitle("Local Network is required to continue. Notifications are optional and only used for forwarded phone alerts.")

            VStack(alignment: .leading, spacing: 18) {
                PermissionActionRow(
                    icon: "network",
                    title: "Local Network",
                    detail: AppModel.localNetworkPermissionReason,
                    actionTitle: model.localNetworkPermissionGrantedForOnboarding ? "Allowed" : "Allow",
                    tint: rowTint,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    isComplete: model.localNetworkPermissionGrantedForOnboarding,
                    action: model.requestLocalNetworkPermissionFromOnboarding
                )

                PermissionActionRow(
                    icon: "bell.badge",
                    title: "Notifications",
                    detail: AppModel.notificationPermissionReason,
                    actionTitle: notificationPermissionActionTitle,
                    tint: rowTint,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    isComplete: model.notificationPermissionGrantedForOnboarding,
                    action: {
                        guard !model.notificationPermissionGrantedForOnboarding else { return }
                        if model.notificationForwardingPermissionDenied {
                            model.openNotificationSettings()
                        } else {
                            model.enableNotificationForwardingFromOnboarding()
                        }
                    }
                )
            }
            .padding(.top, 24)
        }
        .frame(width: innerWidth, alignment: .leading)
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 27, weight: .bold))
            .foregroundStyle(primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15.5, weight: .regular))
            .foregroundStyle(secondaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private var stepIndicator: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                Capsule(style: .continuous)
                    .fill(candidate == step ? rowTint : secondaryText.opacity(0.3))
                    .frame(width: candidate == step ? 18 : 6.5, height: 6.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            switch step {
            case .welcome:
                Button("Later") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(OnboardingPillButtonStyle(kind: .secondary, isDarkMode: isEffectiveDarkMode))

                Spacer()

                Button("Continue") {
                    step = .permissions
                }
                .buttonStyle(OnboardingPillButtonStyle(kind: .primary, isDarkMode: isEffectiveDarkMode))
                .keyboardShortcut(.defaultAction)
            case .permissions:
                Button {
                    step = .welcome
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(OnboardingPillButtonStyle(kind: .secondary, isDarkMode: isEffectiveDarkMode))

                Spacer()

                Button("Get Started") {
                    guard canContinue else { return }
                    model.completeFirstTimeUserOnboarding()
                }
                .buttonStyle(OnboardingPillButtonStyle(kind: .primary, isDarkMode: isEffectiveDarkMode))
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.45)
                .help(canContinue ? "Start using Phone Relay" : "Allow Local Network to continue")
            }
        }
        .overlay(stepIndicator)
        .animation(stepAnimation, value: step)
    }

    private var notificationPermissionActionTitle: String {
        if model.notificationPermissionGrantedForOnboarding { return "Allowed" }
        if model.notificationForwardingPermissionDenied { return "Open Settings" }
        return "Allow"
    }

    private func setupRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            OnboardingRowBadge(systemName: icon, tint: rowTint, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryText)

                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var panelColor: Color {
        isEffectiveDarkMode ? Color(red: 0.105, green: 0.11, blue: 0.118) : .white
    }

    private var primaryText: Color {
        isEffectiveDarkMode
            ? Color(red: 0.93, green: 0.94, blue: 0.95)
            : Color(red: 0.10, green: 0.11, blue: 0.12)
    }

    private var secondaryText: Color {
        isEffectiveDarkMode
            ? Color(red: 0.62, green: 0.64, blue: 0.66)
            : Color(red: 0.45, green: 0.46, blue: 0.48)
    }

    /// Tint for the row badges and the step indicator dots.
    private var rowTint: Color {
        isEffectiveDarkMode ? onboardingCyan : onboardingDeepCyan
    }
}

/// Atlas-style window dot: the only chrome on the borderless onboarding card.
private struct QuitDotButton: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            ZStack {
                Circle()
                    .fill(hovering ? OnboardingWindowDotStyle.closeRed : Color.white.opacity(0.46))
                    .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                if hovering {
                    QuitDotX()
                        .stroke(
                            Color.black.opacity(0.62),
                            style: StrokeStyle(
                                lineWidth: OnboardingWindowDotStyle.xStrokeWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Quit Phone Relay")
        .accessibilityLabel("Quit Phone Relay")
    }
}

enum OnboardingWindowDotStyle {
    static let closeRedComponents = (red: 1.0, green: 0.37, blue: 0.34)
    static let xStrokeWidth: CGFloat = 1.3

    static var closeRed: Color {
        Color(
            red: closeRedComponents.red,
            green: closeRedComponents.green,
            blue: closeRedComponents.blue
        )
    }
}

private struct QuitDotX: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// Capsule buttons in the Atlas onboarding style: filled near-black primary,
/// hairline-outlined secondary (inverted in dark mode).
private struct OnboardingPillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    let isDarkMode: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .frame(height: 42)
            .background(Capsule(style: .continuous).fill(fill))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(stroke, lineWidth: kind == .secondary ? 1 : 0)
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var fill: Color {
        switch kind {
        case .primary:
            return isDarkMode
                ? Color(red: 0.94, green: 0.95, blue: 0.96)
                : Color(red: 0.07, green: 0.08, blue: 0.09)
        case .secondary:
            return isDarkMode ? Color.white.opacity(0.06) : .white
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return isDarkMode ? Color(red: 0.08, green: 0.09, blue: 0.10) : .white
        case .secondary:
            return isDarkMode
                ? Color(red: 0.92, green: 0.93, blue: 0.94)
                : Color(red: 0.12, green: 0.13, blue: 0.14)
        }
    }

    private var stroke: Color {
        isDarkMode ? Color.white.opacity(0.18) : Color.black.opacity(0.14)
    }
}

/// The app icon rendered as hero artwork; falls back to a branded glyph tile
/// when the icns isn't reachable (bare `swift run` debug binaries).
private struct AppIconHeroImage: View {
    var body: some View {
        if let icon = Self.bundledIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [onboardingCyan.opacity(0.9), onboardingDeepCyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private static let bundledIcon: NSImage? = {
        if let appIcon = NSImage(named: "AppIcon") {
            return appIcon
        }
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

/// Circular tinted badge for list-row glyphs (first-run setup steps).
private struct OnboardingRowBadge: View {
    let systemName: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.13))
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

private struct PermissionActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let tint: Color
    let primaryText: Color
    let secondaryText: Color
    let isComplete: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OnboardingRowBadge(systemName: icon, tint: tint, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(primaryText)

                Text(detail)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)

            Spacer(minLength: 10)

            Button(action: action) {
                HStack(spacing: 5) {
                    if isComplete {
                        Image(systemName: "checkmark")
                    }
                    Text(actionTitle)
                }
            }
            .buttonStyle(PermissionRoundedButtonStyle(isComplete: isComplete))
            .disabled(isComplete)
            .padding(.top, 1)
        }
    }
}

/// Small monochrome pill for the permission rows: filled near-black while
/// actionable, soft green once granted.
private struct PermissionRoundedButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    let isComplete: Bool

    private var fillColor: Color {
        if isComplete {
            return Color.green.opacity(colorScheme == .dark ? 0.18 : 0.13)
        }
        return colorScheme == .dark
            ? Color(red: 0.94, green: 0.95, blue: 0.96)
            : Color(red: 0.07, green: 0.08, blue: 0.09)
    }

    private var textColor: Color {
        if isComplete {
            return .green
        }
        return colorScheme == .dark ? Color(red: 0.08, green: 0.09, blue: 0.10) : .white
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(textColor.opacity(configuration.isPressed ? 0.72 : 1))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isComplete ? Color.green.opacity(colorScheme == .dark ? 0.25 : 0.30) : .clear,
                        lineWidth: 1
                    )
            )
    }
}

/// Status dot with an optional outward pulse to signal "actively waiting".
private struct StatusDot: View {
    let color: Color
    let diameter: CGFloat
    let pulses: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            if pulses {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(animate ? 2.4 : 1)
                    .opacity(animate ? 0 : 0.6)
            }
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

/// Brand cyan palette shared by onboarding accents and gradient backgrounds.
private let onboardingDeepCyan = PhoneRelayBrand.deepCyanColor
private let onboardingCyan = PhoneRelayBrand.cyanColor
private let onboardingAccentCyan = onboardingCyan

#if DEBUG
@MainActor
private func connectionPreview() -> some View {
    UserDefaults.standard.set(true, forKey: "hasSeenFirstTimeUserOnboarding")
    let model = AppModel(startBackgroundServices: false)
    return FigmaMirrorExperienceView()
        .environmentObject(model)
}

#Preview("First-run onboarding") {
    FirstRunOnboardingView(onDismiss: {})
        .environmentObject(AppModel(startBackgroundServices: false))
}

#Preview("First-run onboarding — permissions") {
    FirstRunOnboardingView(initialStep: .permissions, onDismiss: {})
        .environmentObject(AppModel(startBackgroundServices: false))
}

#Preview("QR pairing onboarding") {
    connectionPreview()
}
#endif
