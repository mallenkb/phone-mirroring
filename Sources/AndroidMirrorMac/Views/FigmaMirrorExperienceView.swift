import AppKit
import CoreImage
import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
    private let phoneAspect: CGFloat = 894 / 1948
    private let referenceHeight: CGFloat = 884
    private var referenceWidth: CGFloat { referenceHeight * phoneAspect }
    private var isConnecting: Bool {
        model.isPairing || model.isScanning || model.isMirroring
    }
    private let heroIconSize: CGFloat = 36
    private let columnWidth: CGFloat = 330
    private let ctaHeight: CGFloat = 42
    private let accent = Color(red: 0.22, green: 0.78, blue: 0.55)

    var body: some View {
        GeometryReader { proxy in
            let surfaceInset: CGFloat = 0
            let availableWidth = max(0, proxy.size.width - surfaceInset * 2)
            let availableHeight = max(0, proxy.size.height - surfaceInset * 2)
            let scale = max(0.1, min(availableWidth / referenceWidth, availableHeight / referenceHeight))

            ZStack {
                Color.clear

                designSurface
                    .frame(width: referenceWidth, height: referenceHeight)
                    .scaleEffect(scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .onAppear {
            model.ensureQRCodePairingSession()
        }
        .onDisappear {
            model.stopQRCodePairingSession()
        }
    }

    private var designSurface: some View {
        FigmaPhoneFrame {
            connectionContent
        }
    }

    private var connectionContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 130)

            headerGroup

            Spacer(minLength: 26)

            usbConnectionAction

            Text("or")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))
                .padding(.vertical, 22)

            connectionInstruction(
                iconName: "qrcode.viewfinder",
                title: "Scan QR code",
                detail: "Turn on Wireless debugging, choose Pair device with QR code, then scan below.",
                iconColor: .white
            )

            qrPairingPanel
                .padding(.top, 26)

            ctaRow
                .padding(.top, 16)

            Spacer(minLength: 24)

            devicePill

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var headerGroup: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: heroIconSize, weight: .medium))
                .foregroundStyle(accent)

            Text("Connect your Android Phone")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usbConnectionAction: some View {
        Button(action: model.connectViaUSB) {
            connectionInstruction(
                iconName: "cable.connector.horizontal",
                title: "Connect via USB",
                detail: "Use an authorized cable connection. Audio is only attempted on USB.",
                iconColor: .white
            )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }

    private var ctaRow: some View {
        Button(action: model.restartQRCodePairingSession) {
            Text("New QR Code")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: ctaHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.13))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .frame(maxWidth: columnWidth)
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
        iconColor: Color
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
                .frame(width: columnWidth)
        }
        .frame(maxWidth: columnWidth)
    }

    private var qrPairingPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)

            if let payload = model.qrPairingSession?.payload,
               let image = qrImage(from: payload, size: 188) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 188, height: 188)
                    .accessibilityLabel("ADB wireless pairing QR code")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 212, height: 212)
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

    var body: some View {
        ZStack {
            let frameShape = RoundedRectangle(cornerRadius: 40, style: .continuous)

            frameShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.0, green: 0.48, blue: 0.43),
                            Color(red: 0.0, green: 0.22, blue: 0.19)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    frameShape
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )

            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
    }
}
