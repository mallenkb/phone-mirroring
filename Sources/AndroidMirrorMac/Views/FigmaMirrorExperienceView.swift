import SwiftUI

/// Main pre-connection screen. Renders the Figma design at a fixed surface
/// size and scales it to fit the host window.
struct FigmaMirrorExperienceView: View {
    @EnvironmentObject private var model: AppModel
    private let designWidth: CGFloat = 918
    private let designHeight: CGFloat = 2048

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / designWidth, proxy.size.height / designHeight)

            ZStack {
                Color.black

                designSurface
                    .frame(width: designWidth, height: designHeight)
                    .scaleEffect(max(0.1, scale))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var designSurface: some View {
        ZStack {
            FigmaTopChrome(model: model)
                .position(x: 459, y: 50)
                .zIndex(2)

            FigmaPhoneFrame {
                connectionContent
                    .frame(width: 894, height: 1948)
            }
            .frame(width: 894, height: 1948)
            .position(x: 459, y: 1074)
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
                    Text("Pair Device")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 264, height: 96)
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
                .padding(.top, 39)
            }

            if model.isPairing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .padding(.top, 16)
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
                            Color(red: 0.09, green: 0.08, blue: 0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .white.opacity(0.50), radius: 18)
                .shadow(color: .black.opacity(0.92), radius: 18, y: 17)

            content
        }
    }
}

/// Title-bar style header with traffic-light dots and quick action buttons.
struct FigmaTopChrome: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                Circle().fill(Color(red: 1.00, green: 0.35, blue: 0.31))
                Circle().fill(Color(red: 1.00, green: 0.71, blue: 0.18))
                Circle().fill(Color(red: 0.12, green: 0.78, blue: 0.22))
            }
            .frame(width: 120, height: 28)
            .padding(.leading, 40)

            Spacer()
                .frame(width: 187)

            Spacer(minLength: 0)

            Button(action: model.toggleScreenRecording) {
                Image(systemName: model.isRecording ? "stop.circle" : "record.circle")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(Color(red: 1.0, green: 0.08, blue: 0.10))
            }
            .buttonStyle(.plain)
            .frame(width: 69, height: 80)

            Button(action: model.takeScreenshot) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .buttonStyle(.plain)
            .frame(width: 63, height: 80)

            FigmaDivider()

            Button { model.resizeMirror(scale: 0.90) } label: {
                Text("−")
                    .font(.system(size: 49, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 75, height: 80)
            }
            .buttonStyle(.plain)

            Button { model.resizeMirror(scale: 1.10) } label: {
                Text("+")
                    .font(.system(size: 49, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 75, height: 80)
            }
            .buttonStyle(.plain)

            FigmaDivider()

            Button { model.sendAndroidKey("KEYCODE_BACK") } label: {
                Image(systemName: "arrowtriangle.left.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 78, height: 80)
            }
            .buttonStyle(.plain)

            Button { model.sendAndroidKey("KEYCODE_HOME") } label: {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 41, height: 41)
                    .frame(width: 74, height: 80)
            }
            .buttonStyle(.plain)

            Button { model.sendAndroidKey("KEYCODE_APP_SWITCH") } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 46, height: 46)
                    .frame(width: 74, height: 80)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 30)
        }
        .frame(width: 918, height: 100)
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 2)
        )
    }
}

struct FigmaDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.17))
            .frame(width: 4, height: 64)
    }
}
