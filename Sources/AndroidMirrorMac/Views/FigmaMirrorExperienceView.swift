import AppKit
import CoreImage
import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasSeenConnectionOnboarding") private var hasSeenConnectionOnboarding = false
    private let phoneAspect: CGFloat = MirrorContentWindowController.defaultMirrorAspect
    private let edgeBleed: CGFloat = 2
    private var referenceHeight: CGFloat { AppModel.onboardingWindowSize.height }
    private var referenceWidth: CGFloat { referenceHeight * phoneAspect }
    private var isConnecting: Bool {
        model.isPairing || model.isScanning || model.isMirroring || shouldShowMirrorLoading
    }
    private let heroIconSize: CGFloat = 36
    private let maxColumnWidth: CGFloat = 560
    private let qrCodeSize: CGFloat = 188
    private let qrPanelSize: CGFloat = 212
    private let accent = Color(red: 0.22, green: 0.78, blue: 0.55)
    private let qrRefreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private var frameCornerRadius: CGFloat {
        MirrorContentWindowController.onboardingCornerRadius()
    }
    private var shouldShowMirrorLoading: Bool {
        model.isRecoveringConnection
    }
    private var shouldShowFirstRunOnboarding: Bool {
        !hasSeenConnectionOnboarding && model.pairedPhones.isEmpty
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
            if shouldShowFirstRunOnboarding {
                model.stopQRCodePairingSession()
            } else if shouldShowMirrorLoading {
                model.stopQRCodePairingSession()
            } else {
                model.ensureQRCodePairingSession()
            }
        }
        .onReceive(qrRefreshTimer) { _ in
            guard !shouldShowFirstRunOnboarding, !isConnecting else { return }
            model.restartQRCodePairingSession()
        }
        .onChange(of: hasSeenConnectionOnboarding) { hasSeen in
            if hasSeen, !shouldShowMirrorLoading, !shouldShowFirstRunOnboarding {
                model.ensureQRCodePairingSession()
            } else {
                model.stopQRCodePairingSession()
            }
        }
        .onDisappear {
            model.stopQRCodePairingSession()
        }
    }

    @ViewBuilder
    private var designSurface: some View {
        if shouldShowFirstRunOnboarding {
            FirstRunPhoneFrame {
                firstRunOnboardingContent
            }
        } else {
            FigmaPhoneFrame {
                connectionContent
            }
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

    private var firstRunOnboardingContent: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - 72, maxColumnWidth)
            let heightScale = min(1, max(0.76, proxy.size.height / 815))

            VStack(spacing: 0) {
                onboardingVisual(width: contentWidth)
                    .padding(.top, 44 * heightScale)

                VStack(spacing: 10) {
                    Text("Mirror your Android on this Mac")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Pair once over Wi-Fi when your Android and Mac are nearby, or plug in with USB when you want a cable.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: contentWidth)
                }
                .padding(.top, 26 * heightScale)

                VStack(alignment: .leading, spacing: 18 * heightScale) {
                    setupGuideRow(
                        iconName: "wifi",
                        title: "Pair once over Wi-Fi",
                        detail: "Keep your Android and Mac on the same network."
                    )

                    setupGuideRow(
                        iconName: "cable.connector",
                        title: "Turn on USB debugging",
                        detail: "Open Developer options, enable USB debugging, then approve this Mac."
                    )

                    setupGuideRow(
                        iconName: "qrcode.viewfinder",
                        title: "Enable Wireless debugging",
                        detail: "Tap Pair device with QR code, scan here, and Reflect can reconnect."
                    )
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.top, 28 * heightScale)

                Spacer(minLength: 16)

                HStack(spacing: 12) {
                    Spacer()

                    Button("Set Up Later") {
                        hasSeenConnectionOnboarding = true
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())

                    Button("Continue") {
                        hasSeenConnectionOnboarding = true
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func onboardingVisual(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(alignment: .center, spacing: 34) {
                MacBookGlyph(accent: accent)
                    .frame(width: 170, height: 86)

                SignalPathGlyph(accent: accent)
                    .frame(width: 108, height: 48)

                PhoneGlyph()
                    .frame(width: 58, height: 92)
            }
            .padding(.horizontal, 28)
        }
        .frame(width: min(width, 420), height: 176)
    }

    private func setupGuideRow(iconName: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            let heightScale = min(1, max(0.72, proxy.size.height / 815))
            let contentWidth = min(proxy.size.width - 72, maxColumnWidth)
            let qrPanelSize = min(self.qrPanelSize * heightScale, contentWidth * 0.62)
            let qrCodeSize = min(self.qrCodeSize * heightScale, qrPanelSize - 24)

            VStack(spacing: 0) {
                headerGroup(width: contentWidth)

                usbConnectionAction(width: contentWidth)
                    .padding(.top, 34 * heightScale)

                Text("or")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.vertical, 16 * heightScale)

                connectionInstruction(
                    iconName: "qrcode.viewfinder",
                    title: "Scan QR code",
                    detail: "Enable Wireless debugging, tap Pair with QR code, then scan.",
                    iconColor: .white,
                    width: contentWidth
                )

                qrPairingPanel(panelSize: qrPanelSize, codeSize: qrCodeSize)
                    .padding(.top, 22 * heightScale)

                if shouldShowDevicePill {
                    devicePill
                        .padding(.top, 34 * heightScale)
                }
            }
            .padding(.horizontal, 36)
            .frame(width: contentWidth, alignment: .center)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func headerGroup(width: CGFloat) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: heroIconSize, weight: .medium))
                .foregroundStyle(accent)

            Text("Connect your Android phone")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width)
        }
    }

    private func usbConnectionAction(width: CGFloat) -> some View {
        Button(action: model.connectViaUSB) {
            connectionInstruction(
                iconName: "cable.connector.horizontal",
                title: "Connect via USB",
                detail: "Turn on Developer options, enable USB debugging, then connect by cable.",
                iconColor: .white,
                width: width
            )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }

    private var shouldShowDevicePill: Bool {
        model.isSelectedDeviceOnline || !model.pairedPhones.isEmpty
    }

    private var devicePill: some View {
        let online = model.isSelectedDeviceOnline
        let statusColor = online ? accent : Color.white.opacity(0.48)
        let statusText = online ? "Device" : "Offline"

        return HStack(spacing: 10) {
            Circle()
                .fill(statusColor.opacity(0.9))
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.system(size: 14, weight: .semibold))

            Text(model.selectedDevice.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor.opacity(0.85))
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.12))
        )
    }

    private func connectionInstruction(
        iconName: String,
        title: String,
        detail: String,
        iconColor: Color,
        width: CGFloat
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, alignment: .center)

                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text(detail)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width)
        }
        .frame(width: width)
    }

    private func qrPairingPanel(panelSize: CGFloat, codeSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)

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

private struct FirstRunPhoneFrame<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content
    private var cornerRadius: CGFloat {
        MirrorContentWindowController.onboardingCornerRadius()
    }
    private var frameShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            content
        }
        .overlay(
            frameShape
                .inset(by: 0.5)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.1), lineWidth: 1)
        )
        .clipShape(frameShape)
    }
}

private struct MacBookGlyph: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1.2)
                )
                .frame(width: 132, height: 82)
                .offset(y: -9)

            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)
                .offset(y: -42)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.16))
                .frame(width: 154, height: 6)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 54, height: 3)
                .offset(y: -1)
        }
    }
}

private struct SignalPathGlyph: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            SignalArc(accent: accent, rotation: 5)
            SignalArc(accent: accent, rotation: -2)
            SignalArc(accent: accent, rotation: -6)
                .scaleEffect(1.18)
        }
        .opacity(0.76)
    }
}

private struct SignalArc: View {
    let accent: Color
    let rotation: Double

    var body: some View {
        ArcShape(startAngle: .degrees(62), endAngle: .degrees(118))
            .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(rotation))
    }
}

private struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

private struct PhoneGlyph: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1.2)
            )
            .overlay(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 18, height: 4)
                    .padding(.top, 9)
            }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.14, green: 0.78, blue: 0.25).opacity(configuration.isPressed ? 0.76 : 1))
            )
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.18, green: 0.92, blue: 0.36))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        Color(red: 0.12, green: 0.36, blue: 0.18)
                            .opacity(configuration.isPressed ? 0.34 : colorScheme == .dark ? 0.24 : 0.12)
                    )
            )
    }
}
