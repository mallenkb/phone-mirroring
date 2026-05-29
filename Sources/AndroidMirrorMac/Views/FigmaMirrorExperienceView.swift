import AppKit
import CoreImage
import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var connectionMode: ConnectionMode = .wifi
    @State private var wirelessHost = ""
    @State private var wirelessPort = ""
    @State private var wirelessPairingPort = ""
    @State private var wirelessPairingCode = ""
    private let phoneAspect: CGFloat = 894 / 1948
    private var isConnecting: Bool {
        model.isPairing || model.isScanning || model.isMirroring
    }
    private var contentSpacing: CGFloat {
        connectionMode == .wifi ? 10 : 18
    }
    private var verticalPadding: CGFloat {
        connectionMode == .wifi ? 24 : 34
    }
    private var heroIconSize: CGFloat {
        connectionMode == .wifi ? 34 : 44
    }

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
            if connectionMode == .wifi {
                model.ensureQRCodePairingSession()
            }
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
        VStack(spacing: contentSpacing) {
            Spacer()

            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: heroIconSize, weight: .medium))
                .foregroundStyle(Color(red: 0.20, green: 0.74, blue: 0.51))

            Text("Connect your Android Phone")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                connectionModeButton(.usb)
                connectionModeButton(.wifi)
                connectionModeButton(.manual)
            }
            .padding(4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )

            VStack(spacing: 7) {
                ForEach(connectionMode.descriptionLines, id: \.self) { line in
                    Text(line)
                }
            }
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white.opacity(0.86))
            .multilineTextAlignment(.center)
            .lineLimit(nil)

            if connectionMode == .wifi {
                qrPairingPanel
            }

            if connectionMode == .manual {
                manualWirelessFields
            }

            Button(action: connectSelectedMode) {
                VStack(spacing: 5) {
                    Text(isConnecting ? "Connecting" : connectionMode.buttonTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if isConnecting {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 118)
                    }
                }
                .frame(minWidth: 110, minHeight: 42)
                .padding(.horizontal, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.02, green: 0.46, blue: 0.92))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .padding(.top, 4)

            if let status = model.diagnostics.first?.message {
                Text(status)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, verticalPadding)
    }

    private func connectionModeButton(_ mode: ConnectionMode) -> some View {
        let isSelected = connectionMode == mode

        return Button {
            let previousMode = connectionMode
            connectionMode = mode
            if mode == .wifi {
                model.ensureQRCodePairingSession()
            } else if previousMode == .wifi {
                model.stopQRCodePairingSession()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color(red: 0.07, green: 0.08, blue: 0.07) : .white.opacity(0.78))
            .frame(minWidth: 58, minHeight: 28)
            .padding(.horizontal, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.92) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }

    private var qrPairingPanel: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.70), lineWidth: 1)
                    )

                if let payload = model.qrPairingSession?.payload,
                   let image = qrImage(from: payload, size: 144) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 118, height: 118)
                        .accessibilityLabel("ADB wireless pairing QR code")
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 132, height: 132)

            HStack(spacing: 6) {
                if model.isQRCodePairingWaiting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                Text(model.isQRCodePairingWaiting ? "Waiting for scan" : "Ready to scan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }

            Text("Open Wireless debugging > Pair device with QR code, then scan.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 238)
        .padding(.vertical, 2)
    }

    private var manualWirelessFields: some View {
        VStack(spacing: 8) {
            TextField("Phone IP address", text: $wirelessHost)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(fieldBackground)

            TextField("Port", text: $wirelessPort)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(fieldBackground)

            TextField("Pairing port (optional)", text: $wirelessPairingPort)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(fieldBackground)

            TextField("Pairing code (optional)", text: $wirelessPairingCode)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(fieldBackground)
        }
        .frame(maxWidth: 230)
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

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }

    private func connectSelectedMode() {
        switch connectionMode {
        case .wifi:
            model.restartQRCodePairingSession()
        case .usb:
            model.connectViaUSB()
        case .manual:
            model.connectWirelessly(
                host: wirelessHost,
                port: wirelessPort,
                pairingPort: wirelessPairingPort,
                pairingCode: wirelessPairingCode
            )
        }
    }
}

private enum ConnectionMode: Equatable {
    case wifi
    case usb
    case manual

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .usb: "USB"
        case .manual: "Manual"
        }
    }

    var symbolName: String {
        switch self {
        case .wifi: "wifi"
        case .usb: "cable.connector"
        case .manual: "number"
        }
    }

    var buttonTitle: String {
        switch self {
        case .wifi: "New QR Code"
        case .usb: "Connect USB"
        case .manual: "Connect Manual"
        }
    }

    var descriptionLines: [String] {
        switch self {
        case .wifi:
            [
                "Open Android Wireless debugging.",
                "Tap Pair device with QR code and scan.",
                "The app pairs and starts Wi-Fi mirroring."
            ]
        case .usb:
            [
                "On Android, open Developer options,",
                "turn on USB debugging, then approve this Mac.",
                "Keep your phone plugged in while mirroring."
            ]
        case .manual:
            [
                "Enter IP and wireless connect port.",
                "Add pairing port and code for first-time setup.",
                "Use this when discovery does not find the phone."
            ]
        }
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
