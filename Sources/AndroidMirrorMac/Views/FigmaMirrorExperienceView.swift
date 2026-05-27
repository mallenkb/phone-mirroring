import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
    private let designWidth: CGFloat = 894
    private let designHeight: CGFloat = 1948
    private var isConnecting: Bool {
        model.isPairing || model.isScanning || model.isMirroring
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / designWidth, proxy.size.height / designHeight)

            ZStack {
                Color.clear

                designSurface
                    .frame(width: designWidth, height: designHeight)
                    .scaleEffect(max(0.1, scale))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var designSurface: some View {
        FigmaPhoneFrame {
            connectionContent
                .frame(width: designWidth, height: designHeight)
        }
    }

    private var connectionContent: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 100, weight: .medium))
                .foregroundStyle(Color(red: 0.20, green: 0.74, blue: 0.51))
                .padding(.bottom, 36)

            VStack(spacing: 34) {
                Text("Connect your Android Phone")
                    .font(.system(size: 43, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: 15) {
                    Text("Use Wi-Fi: plug in once, approve")
                    Text("debugging, then the app switches your")
                    Text("phone to Wi-Fi. After mirroring starts, you")
                    Text("can unplug.")
                }
                .font(.system(size: 35, weight: .regular))
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

                Text("Use USB: mirror through the cable only.")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.top, 37)

                Button(action: model.autoPairWirelessly) {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.02, green: 0.46, blue: 0.92))

                        VStack(spacing: 8) {
                            Text(isConnecting ? "Connecting" : "Pair Device")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .center)

                            if isConnecting {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .tint(.white)
                                    .frame(width: 196)
                            }
                        }
                        .frame(width: 230, height: 72, alignment: .center)
                    }
                    .frame(width: 264, height: 96)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isConnecting)
                .padding(.top, 39)

                if let status = model.diagnostics.first?.message {
                    Text(status)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(width: 640)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 20)
                }
            }

            Spacer()
                .frame(height: 541)
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
