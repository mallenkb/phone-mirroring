import AppKit
import CoreImage
import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
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
        model.isManualUSBConnectDisabled
    }
    private let heroIconSize: CGFloat = 36
    private let maxColumnWidth: CGFloat = 620
    private let qrCodeSize: CGFloat = 216
    private let qrPanelSize: CGFloat = 244
    private let accent = onboardingTeal
    private let qrRefreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private var frameCornerRadius: CGFloat {
        MirrorContentWindowController.onboardingCornerRadius()
    }
    private var shouldShowMirrorLoading: Bool {
        model.isRecoveringConnection
    }

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
            if shouldShowMirrorLoading {
                model.stopQRCodePairingSession()
            } else {
                model.ensureQRCodePairingSession()
            }
        }
        .onReceive(qrRefreshTimer) { _ in
            guard !isConnecting else { return }
            model.restartQRCodePairingSession()
        }
        .onDisappear {
            model.stopQRCodePairingSession()
        }
    }

    @ViewBuilder
    private var designSurface: some View {
        FigmaPhoneFrame {
            connectionContent
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        if shouldShowMirrorLoading {
            reconnectingContent
        } else {
            onboardingContent
        }
    }

    private var reconnectingContent: some View {
        MirrorLoadingSurface(
            statusText: "Reconnecting to",
            deviceName: model.selectedDevice.name,
            cornerRadius: frameCornerRadius,
            repeatsProgress: true
        )
    }

    private var onboardingContent: some View {
        GeometryReader { proxy in
            // A single continuous scale derived from the available space (which
            // tracks the host display's resolution, since the onboarding window
            // is sized from it). Every font and metric multiplies by this, so
            // text shrinks smoothly on lower-resolution displays and only
            // reaches its full design size at high resolution. No hard floors
            // on individual fonts — that's what previously kept them oversized.
            let scale = min(1, max(0.5, min(proxy.size.height / 815, proxy.size.width / 390)))
            let usesCompactLayout = proxy.size.height <= 760 || proxy.size.width <= 360
            let availableWidth = proxy.size.width - (usesCompactLayout ? 44 : 72)
            let contentWidth = min(availableWidth, maxColumnWidth)
            let qrPanelSize = min(self.qrPanelSize * scale, contentWidth * (usesCompactLayout ? 0.64 : 0.72))
            // Keep the white border around the QR a constant fraction of the
            // panel so it doesn't look like oversized padding when scaled down.
            let qrCodeSize = qrPanelSize * 0.88

            VStack(spacing: 0) {
                if let error = model.activeError {
                    ErrorBanner(
                        error: error,
                        accent: accent,
                        scale: scale,
                        onOpenLog: model.revealLogFile,
                        onDismiss: model.dismissError
                    )
                    .frame(width: contentWidth)
                    .padding(.bottom, (usesCompactLayout ? 14 : 18) * scale)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                headerGroup(width: contentWidth, scale: scale)

                USBConnectButton(
                    accent: accent,
                    scale: scale,
                    isConnecting: isUSBButtonBusy,
                    disabled: isUSBButtonBusy,
                    action: model.connectViaUSB
                )
                .frame(width: contentWidth)
                .padding(.top, (usesCompactLayout ? 28 : 40) * scale)

                Text("or")
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, (usesCompactLayout ? 18 : 26) * scale)

                connectionInstruction(
                    iconName: "qrcode.viewfinder",
                    title: "Scan QR code",
                    detail: "Enable Wireless debugging, tap Pair with QR code, then scan.",
                    iconColor: .white,
                    width: contentWidth,
                    scale: scale,
                    usesCompactTitleLayout: usesCompactLayout
                )

                qrPairingPanel(panelSize: qrPanelSize, codeSize: qrCodeSize)
                    .padding(.top, (usesCompactLayout ? 18 : 26) * scale)
                    .frame(width: contentWidth, alignment: .center)

                if shouldShowDevicePill {
                    devicePill(width: contentWidth, scale: scale)
                        .padding(.top, (usesCompactLayout ? 22 : 32) * scale)
                }
            }
            .padding(.horizontal, usesCompactLayout ? 22 : 36)
            .frame(width: contentWidth, alignment: .center)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .animation(.easeInOut(duration: 0.22), value: model.activeError)
        }
    }

    private func headerGroup(width: CGFloat, scale: CGFloat) -> some View {
        VStack(spacing: 16 * scale) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: heroIconSize * scale, weight: .medium))
                .foregroundStyle(accent)

            VStack(spacing: 5 * scale) {
                Text("Connect your Android phone")
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width)

                Text("Mirror its screen right here on your Mac.")
                    .font(.system(size: 13.5 * scale, weight: .regular))
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width)
            }
        }
    }

    private var shouldShowDevicePill: Bool {
        model.isSelectedDeviceOnline || !model.pairedPhones.isEmpty
    }

    private func devicePill(width: CGFloat, scale: CGFloat) -> some View {
        let online = model.isSelectedDeviceOnline
        let connecting = model.isActivelyConnecting
        let statusText = model.connectionStatusText
        let isActive = online || connecting
        let dotColor = isActive ? accent : Color.white.opacity(0.42)
        let fontSize = 12 * scale

        return HStack(spacing: 8 * scale) {
            StatusDot(color: dotColor, diameter: 7 * scale, pulses: connecting)

            Text(statusText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(isActive ? 0.92 : 0.82))
                .fixedSize()

            Text(model.connectionDeviceLabel)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14 * scale)
        .frame(height: 30 * scale)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .frame(maxWidth: width, alignment: .center)
    }

    private func connectionInstruction(
        iconName: String,
        title: String,
        detail: String,
        iconColor: Color,
        width: CGFloat,
        scale: CGFloat,
        usesCompactTitleLayout: Bool = false
    ) -> some View {
        VStack(spacing: 6 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: usesCompactTitleLayout ? 5 : 8 * scale) {
                Image(systemName: iconName)
                    .font(.system(size: 16 * scale, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: usesCompactTitleLayout ? 12 : 20 * scale, alignment: .center)

                instructionTitle(title, scale: scale)
                    .layoutPriority(1)
            }
            .frame(width: width, alignment: .center)

            Text(detail)
                .font(.system(size: 14 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(2 * scale)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width)
        }
        .frame(width: width)
    }

    private func instructionTitle(_ title: String, scale: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 18 * scale, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func qrPairingPanel(panelSize: CGFloat, codeSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
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
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.48, blue: 0.43),
                    Color(red: 0.0, green: 0.22, blue: 0.19)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
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

/// Standalone first-run onboarding, hosted in its own content-sized window that
/// is completely separate from the connection/mirror window — so its sizing and
/// chrome can never affect the mirror frame. The view sizes to its own content
/// (fixed width, intrinsic height, real bottom padding) so the host window can
/// wrap it. It dismisses itself via `onDismiss` when the user proceeds or as
/// soon as a live device (USB or wireless) appears.
struct FirstRunOnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasSeenFirstTimeUserOnboarding") private var hasSeen = false
    let onDismiss: () -> Void

    private let accent = onboardingTeal
    private let contentWidth: CGFloat = 540

    private var isEffectiveDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var body: some View {
        VStack(spacing: 0) {
            MirroringLoopVisual(accent: accent)
                .frame(width: 380, height: 176)

            VStack(spacing: 8) {
                Text("Mirror your Android on this Mac")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Connect with USB or scan a QR code to pair wirelessly.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(secondaryText)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: contentWidth)
            .padding(.top, 18)

            VStack(spacing: 14) {
                setupRow(
                    icon: "cable.connector",
                    title: "USB",
                    detail: "Plug in your phone and allow USB debugging."
                )

                Divider().overlay(cardStroke)

                setupRow(
                    icon: "qrcode.viewfinder",
                    title: "Wireless",
                    detail: "Scan a QR code from your phone's Wireless debugging settings."
                )

                Divider().overlay(cardStroke)

                setupRow(
                    icon: "wifi",
                    title: "Keep devices nearby",
                    detail: "For wireless pairing, keep your phone and Mac on the same Wi-Fi network."
                )

                Divider().overlay(cardStroke)

                setupRow(
                    icon: "bell.badge",
                    title: "Mac notifications",
                    detail: AppModel.notificationPermissionReason
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(width: contentWidth)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardFill)
            )
            .padding(.top, 24)

            HStack(spacing: 12) {
                Button("Later") {
                    NSApplication.shared.terminate(nil)
                }
                    .buttonStyle(OnboardingSecondaryButtonStyle())

                Button("Continue") {
                    model.enableNotificationForwardingFromOnboarding()
                    hasSeen = true
                }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
            }
            .padding(.top, 30)
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 34)
        .frame(width: contentWidth + 80)
        .background(background)
        .onAppear {
            if hasSeen || model.isSelectedDeviceOnline { onDismiss() }
        }
        .onChange(of: hasSeen) { seen in
            if seen { onDismiss() }
        }
        .onChange(of: model.isSelectedDeviceOnline) { online in
            if online { onDismiss() }
        }
    }

    private func setupRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            OnboardingRowBadge(systemName: icon, tint: accent, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(primaryText)

                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
    }

    private var background: some View {
        LinearGradient(colors: backgroundColors, startPoint: .top, endPoint: .bottom)
    }

    private var backgroundColors: [Color] {
        isEffectiveDarkMode
            ? [Color(red: 0.105, green: 0.108, blue: 0.103), Color(red: 0.075, green: 0.082, blue: 0.078)]
            : [Color(red: 0.965, green: 0.958, blue: 0.936), Color(red: 0.925, green: 0.94, blue: 0.918)]
    }

    private var primaryText: Color {
        isEffectiveDarkMode
            ? Color(red: 0.92, green: 0.93, blue: 0.91)
            : Color(red: 0.13, green: 0.14, blue: 0.13)
    }

    private var secondaryText: Color {
        isEffectiveDarkMode
            ? Color(red: 0.68, green: 0.7, blue: 0.67)
            : Color(red: 0.38, green: 0.4, blue: 0.38)
    }

    private var cardFill: Color {
        isEffectiveDarkMode ? Color.white.opacity(0.045) : Color.white.opacity(0.55)
    }

    private var cardStroke: Color {
        isEffectiveDarkMode ? Color.white.opacity(0.045) : Color.black.opacity(0.05)
    }
}

private struct MirroringLoopVisual: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color
    private let cycle: Double = 12.0
    private let baseAspect: CGFloat = 1600.0 / 898.0
    private let screenAspect: CGFloat = 600.0 / 1338.0
    private let startLeft: CGFloat = 0.00812
    private let startTop: CGFloat = 0.19376
    private let startW: CGFloat = 0.17625
    private let endLeft: CGFloat = 0.46812
    private let endTop: CGFloat = 0.18486
    private let endW: CGFloat = 0.14125
    private let flyingScreenScale: CGFloat = 1.0
    private var isEffectiveDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = loopPhase(at: timeline.date)
            let cast = castState(for: phase)

            GeometryReader { proxy in
                let stageW = min(proxy.size.width, proxy.size.height * baseAspect)
                let stageH = stageW / baseAspect
                let sW = stageW * startW
                let sH = sW / screenAspect
                let sX = stageW * startLeft
                let sY = stageH * startTop

                ZStack(alignment: .topLeading) {
                    ResourceImage(name: "base_scene", extension: "png")
                        .frame(width: stageW, height: stageH)
                        .brightness(isEffectiveDarkMode ? -0.2 : -0.04)
                        .contrast(isEffectiveDarkMode ? 1.08 : 1.04)
                        .saturation(isEffectiveDarkMode ? 0.82 : 0.96)

                    ResourceImage(name: "phone_screen", extension: "png")
                        .frame(width: sW * flyingScreenScale, height: sH * flyingScreenScale)
                        .scaleEffect(cast.scale, anchor: .topLeading)
                        .offset(x: sX + cast.offsetX * stageW, y: sY + cast.offsetY * stageH)
                        .shadow(
                            color: Color(red: 30 / 255, green: 40 / 255, blue: 25 / 255).opacity(0.16),
                            radius: 12,
                            x: 0,
                            y: 12
                        )
                        .opacity(cast.opacity)
                }
                .frame(width: stageW, height: stageH)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel("Animation showing the phone screen moving to the Mac for mirroring")
    }

    private func loopPhase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
    }

    private func castState(for phase: Double) -> CastState {
        let scale = endW / (startW * flyingScreenScale)
        let dx = endLeft - startLeft
        let dy = endTop - startTop
        let lift: CGFloat = 0.08
        let preHold = 0.5 / cycle
        let flight = 2.2 / cycle
        let holdLap = 3.5 / cycle
        let fadeOut = 0.8 / cycle
        let snap = 0.1 / cycle
        let fadeIn = 0.8 / cycle
        let holdStart = preHold + flight
        let fadeStart = holdStart + holdLap
        let snapStart = fadeStart + fadeOut
        let fadeInStart = snapStart + snap

        switch phase {
        case ..<preHold:
            return CastState()
        case ..<holdStart:
            let t = CGFloat((phase - preHold) / flight)
            let eased = smootherStep(t)
            let arc = sin(.pi * eased) * lift
            return CastState(
                offsetX: dx * eased,
                offsetY: dy * eased - arc,
                scale: 1 + (scale - 1) * eased,
                opacity: 1
            )
        case ..<fadeStart:
            return CastState(offsetX: dx, offsetY: dy, scale: scale, opacity: 1)
        case ..<snapStart:
            let t = (phase - fadeStart) / fadeOut
            return CastState(offsetX: dx, offsetY: dy, scale: scale, opacity: 1 - t)
        case ..<fadeInStart:
            return CastState(opacity: 0)
        case ..<(fadeInStart + fadeIn):
            let t = (phase - fadeInStart) / fadeIn
            return CastState(opacity: Double(cubicEaseInOut(CGFloat(t))))
        default:
            return CastState()
        }
    }

    private func cubicEaseInOut(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Perlin smootherstep: 6t^5 - 15t^4 + 10t^3. Zero first *and* second
    /// derivative at both ends, so the phone glides continuously from start to
    /// finish with no perceptible acceleration "snap" at either end.
    private func smootherStep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

private struct CastState {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1
}

private struct ResourceImage: View {
    let name: String
    let `extension`: String

    var body: some View {
        if let url = Bundle.module.url(forResource: name, withExtension: `extension`),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
        } else {
            Color.clear
        }
    }
}

/// Rounded tinted badge for list-row glyphs (first-run setup steps).
private struct OnboardingRowBadge: View {
    let systemName: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// Full-width USB action with an obvious tappable surface and hover feedback.
private struct USBConnectButton: View {
    let accent: Color
    let scale: CGFloat
    let isConnecting: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    private var corner: CGFloat { 14 * scale }
    private var title: String { isConnecting ? "Connecting..." : "Connect via USB" }
    private var detail: String {
        isConnecting
            ? "Checking the current device. USB connect is paused briefly."
            : "Enable USB debugging, then plug in your cable."
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13 * scale) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                        .fill(Color.white.opacity(isConnecting ? 0.16 : 0.12))
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .scaleEffect(max(0.75, scale))
                    } else {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.system(size: 16 * scale, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 38 * scale, height: 38 * scale)

                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(title)
                        .font(.system(size: 15.5 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(isConnecting ? 0.95 : 1))
                    Text(detail)
                        .font(.system(size: 12.5 * scale, weight: .regular))
                        .foregroundStyle(.white.opacity(isConnecting ? 0.76 : 0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(isConnecting ? 0.22 : 0.5))
            }
            .padding(.horizontal, 15 * scale)
            .padding(.vertical, 12 * scale)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.white.opacity(isConnecting ? 0.105 : (hovering && !disabled ? 0.14 : 0.075)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.white.opacity(isConnecting ? 0.26 : (hovering && !disabled ? 0.30 : 0.16)), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isConnecting)
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

/// Brand teal shared by the onboarding accent icons and call-to-action buttons.
private let onboardingTeal = Color(red: 0.0, green: 0.66, blue: 0.59)

/// Dismissible failure card shown on the connection screen when mirroring,
/// pairing, or adb hits a problem — so failures aren't silent.
private struct ErrorBanner: View {
    let error: AppModel.UserFacingError
    let accent: Color
    let scale: CGFloat
    let onOpenLog: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))

                Text(error.title)
                    .font(.system(size: 13.5 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4 * scale)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(4 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(error.message)
                .font(.system(size: 12 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
                .lineSpacing(1.5 * scale)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onOpenLog) {
                Text("Open Log")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 2 * scale)
        }
        .padding(.horizontal, 13 * scale)
        .padding(.vertical, 11 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(Color(red: 0.42, green: 0.13, blue: 0.11).opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.5, blue: 0.42).opacity(0.32), lineWidth: 1)
                )
        )
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(onboardingTeal.opacity(configuration.isPressed ? 0.78 : 1))
            )
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.80, blue: 0.72)
            : Color(red: 0.0, green: 0.52, blue: 0.47)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        onboardingTeal
                            .opacity(configuration.isPressed ? 0.30 : colorScheme == .dark ? 0.18 : 0.12)
                    )
            )
    }
}

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

#Preview("QR pairing onboarding") {
    connectionPreview()
}
#endif
