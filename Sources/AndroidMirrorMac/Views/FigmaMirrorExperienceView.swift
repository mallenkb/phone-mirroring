import AppKit
import CoreImage
import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
    private let phoneAspect: CGFloat = 894 / 1948
    private var isConnecting: Bool {
        model.isPairing || model.isScanning || model.isMirroring
    }
    private let heroIconSize: CGFloat = 36
    private let columnWidth: CGFloat = 286
    private let ctaHeight: CGFloat = 42
    private let accent = Color(red: 0.22, green: 0.78, blue: 0.55)
    private let primaryBlue = Color(red: 0.02, green: 0.46, blue: 0.92)

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * phoneAspect)
            let height = min(proxy.size.height, width / phoneAspect)

            ZStack {
                Color.clear

                designSurface
                    .frame(width: width, height: height)
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
        VStack(spacing: 20) {
            headerGroup

            instructionsGroup

            qrPairingPanel

            ctaRow
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var headerGroup: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: heroIconSize, weight: .medium))
                .foregroundStyle(accent)

            Text("Connect your Android Phone")
                .font(.system(size: 19, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var instructionsGroup: some View {
        VStack(spacing: 16) {
            connectionInstruction(
                iconName: "cable.connector",
                title: "Connect via USB",
                detail: "Turn on USB debugging, plug in the phone, and approve this Mac."
            )

            connectionInstruction(
                iconName: "qrcode.viewfinder",
                title: "Scan QR code",
                detail: "Turn on Wireless debugging, choose Pair device with QR code, then scan below."
            )
        }
        .frame(maxWidth: columnWidth)
    }

    private var ctaRow: some View {
        HStack(spacing: 10) {
            Button(action: model.connectViaUSB) {
                HStack(spacing: 7) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Text(isConnecting ? "Connecting" : "Connect via USB")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: ctaHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(primaryBlue)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: primaryBlue.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)

            Button(action: model.restartQRCodePairingSession) {
                Text("New QR Code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: ctaHeight)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
        }
        .frame(maxWidth: columnWidth)
    }

    private func connectionInstruction(iconName: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var qrPairingPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)

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
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.47, green: 0.41, blue: 0.27),
                            Color(red: 0.18, green: 0.16, blue: 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )

            content
        }
    }
}
