import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab: SettingsTab = .devices

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case devices = "Devices"
        case mirroring = "Mirroring"
        case about = "About"

        var id: String { rawValue }
    }

    private var records: [PairedPhoneRecord] {
        AppModel.recordsByMostRecent(model.pairedPhones)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabPicker

            ScrollView {
                tabContent
                    .padding(.bottom, 4)
            }

            if selectedTab == .devices {
                clearDevicesRow
            }
        }
        .padding(24)
        .frame(width: 660, height: 600)
    }

    private var tabPicker: some View {
        Picker("Mirroring settings section", selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .frame(width: 450, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .devices:
            devicesTab
        case .mirroring:
            mirroringTab
        case .about:
            aboutTab
        }
    }

    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            if records.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(records) { record in
                        PairedPhoneRow(
                            record: record,
                            isOnline: isOnline(record),
                            isActive: isActive(record),
                            onConnect: { model.connect(record: record) },
                            onDisconnect: { model.stopMirroring() },
                            onForget: { model.forgetPairedPhone(id: record.id) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var mirroringTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            mirrorQualitySection
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            aboutIdentitySection
            aboutPrivacySection
            aboutSupportSection
            aboutLegalSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var clearDevicesRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Clearing devices removes saved reconnect history. You will need to pair or connect again from scratch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Clear All Devices", role: .destructive) {
                model.forgetAllPairedPhones()
            }
            .buttonStyle(DestructiveSettingsButtonStyle())
            .disabled(records.isEmpty)
        }
    }

    private var mirrorQualitySection: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                settingsLeadingIcon("slider.horizontal.3", isActive: true)
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mirroring quality")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Lower the resolution or bitrate for smoother mirroring on slow links. Active mirrors restart automatically to apply changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        qualityPicker(
                            "Resolution", suffix: "px",
                            selection: $model.mirrorMaxSize,
                            options: [1080, 1280, 1600, 1920, 2560]
                        )
                        qualityPicker(
                            "Bitrate", suffix: "Mbps",
                            selection: $model.mirrorBitRateMbps,
                            options: [2, 4, 8, 16, 24]
                        )
                        frameRatePicker
                        Spacer(minLength: 0)
                    }
                }
            }

            settingsScrollSpeedRow

            settingsToggleRow(
                icon: "display",
                isOn: $model.mirrorScreenOffAfterThirtySecondsEnabled,
                title: "Turn phone screen off after 30 seconds",
                subtitle: "Keeps mirroring active on this Mac while the phone’s physical display goes dark. Use ⌘L to do this manually.",
                detail: nil
            )

            settingsToggleRow(
                icon: "speaker.wave.2",
                isOn: $model.mirrorAudioEnabled,
                title: "Route phone audio to this Mac",
                subtitle: model.mirrorAudioEnabled
                    ? "On by default. Phone audio plays through this Mac while mirroring; changing this restarts the mirror."
                    : "Audio forwarding is off. Phone audio stays on the phone; changing this restarts the mirror.",
                detail: nil
            )

            settingsToggleRow(
                icon: "doc.on.clipboard",
                isOn: $model.clipboardSyncEnabled,
                title: "Sync clipboard with phone",
                subtitle: "Keeps Mac and Android clipboards in sync and enables paste-to-phone with ⌘V.",
                detail: nil
            )

            settingsToggleRow(
                icon: "keyboard",
                isOn: $model.keyboardInputEnabled,
                title: "Forward keyboard input",
                subtitle: "Sends typing and supported shortcuts to the mirrored phone while the mirror is focused.",
                detail: nil
            )

            settingsToggleRow(
                icon: "tray.and.arrow.down",
                isOn: $model.dragAndDropFileTransferEnabled,
                title: "Allow drag-and-drop file transfer",
                subtitle: "Installs dropped APKs or copies files to the phone’s Download folder.",
                detail: nil
            )

            settingsToggleRow(
                icon: "bell.badge",
                isOn: $model.notificationForwardingEnabled,
                title: "Forward phone notifications to this Mac",
                subtitle: AppModel.notificationPermissionReason,
                detail: model.notificationForwardingPermissionDenied
                    ? "macOS is blocking notifications for PhoneRelay. Enable this app in System Settings, then turn this switch on again."
                    : "Group summaries and ongoing items (music, navigation) are skipped. macOS will ask for notification permission the first time."
            )

            if model.notificationForwardingPermissionDenied {
                Button("Open macOS Notification Settings") {
                    model.openNotificationSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.leading, 42)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var aboutIdentitySection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("PhoneRelay")
                    .font(.system(size: 18, weight: .semibold))
                Text("Local-first Android mirroring for macOS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    labeledBadge("Version", bundleVersion)
                    labeledBadge("Build", bundleBuild)
                    labeledBadge("Bundle ID", bundleIdentifier)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var aboutPrivacySection: some View {
        aboutSection(
            icon: "hand.raised",
            title: "Privacy Policy",
            subtitle: "Shown in-app so the policy remains readable without opening an external page."
        ) {
            aboutTextBlock(AboutContent.privacyPolicy)
        }
    }

    private var aboutSupportSection: some View {
        aboutSection(
            icon: "questionmark.circle",
            title: "Support",
            subtitle: "The details below help diagnose setup, pairing, and mirroring issues."
        ) {
            aboutTextBlock(AboutContent.supportDetails)
        }
    }

    private var aboutLegalSection: some View {
        aboutSection(
            icon: "doc.text",
            title: "Legal",
            subtitle: "PhoneRelay's app license and bundled open-source notices are shown locally."
        ) {
            aboutTextBlock(title: "Open Source License", AboutContent.projectLicense)
            Divider()
            aboutTextBlock(title: "Third-Party Notices", AboutContent.thirdPartyNotices)
        }
    }

    private func aboutSection<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            settingsLeadingIcon(icon, isActive: true)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func labeledBadge(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 180, alignment: .leading)
    }

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
    }

    private var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.mallenkb.PhoneRelay"
    }

    private func aboutTextBlock(title: String? = nil, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsLeadingIcon(_ icon: String, isActive: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 28, height: 28, alignment: .top)
    }
    private func settingsToggleRow(
        icon: String,
        isOn: Binding<Bool>,
        title: String,
        subtitle: String,
        detail: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28, alignment: .top)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 24)

                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func qualityPicker(
        _ title: String,
        suffix: String,
        selection: Binding<Int>,
        options: [Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { value in
                    Text("\(value) \(suffix)").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 116, alignment: .leading)
        }
        .frame(width: 140, alignment: .leading)
    }

    /// 0 means automatic; positive values fix the scrcpy frame-rate ceiling.
    private var frameRatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Frame rate".uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $model.mirrorMaxFps) {
                Text("Auto").tag(0)
                ForEach([30, 60, 90, 120], id: \.self) { value in
                    Text("\(value) Hz").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 116, alignment: .leading)
        }
        .frame(width: 140, alignment: .leading)
    }

    private var settingsScrollSpeedRow: some View {
        HStack(alignment: .top, spacing: 14) {
            settingsLeadingIcon("scroll", isActive: true)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirror scroll speed")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Applies only to mouse wheel and trackpad scrolling inside the mirrored phone window.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                mirrorScrollSpeedPicker
            }
        }
    }

    private var mirrorScrollSpeedPicker: some View {
        Picker("", selection: $model.mirrorScrollSpeedPercent) {
            Text("Slow").tag(10)
            Text("Normal").tag(20)
            Text("Fast").tag(35)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 260, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No remembered devices")
                .font(.headline)
            Text("Devices will appear here after you connect or pair them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func isOnline(_ record: PairedPhoneRecord) -> Bool {
        if model.isSelectedDeviceOnline,
           recordMatchesSelectedDevice(record) {
            return true
        }

        return AppModel.rememberedConnectablePhone(
            for: record,
            in: model.discoveredPhones
        ) != nil
    }

    private func recordMatchesSelectedDevice(_ record: PairedPhoneRecord) -> Bool {
        isActive(record)
    }

    private func isActive(_ record: PairedPhoneRecord) -> Bool {
        guard model.isMirroring else { return false }
        let selected = model.selectedDevice
        return selected.id == record.id
            || selected.adbSerial == record.lastAddress
            || selected.adbSerial == record.id
            || (
                record.displayName.localizedCaseInsensitiveCompare(selected.name) == .orderedSame
                && record.displayName.localizedCaseInsensitiveCompare("Android device") != .orderedSame
            )
    }
}

private struct DestructiveSettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Color.red : Color.secondary)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((isEnabled ? Color.red : Color.secondary).opacity(configuration.isPressed ? 0.2 : 0.12))
            )
    }
}

private struct PairedPhoneRow: View {
    let record: PairedPhoneRecord
    let isOnline: Bool
    let isActive: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TemplateResourceIcon(
                name: phoneIconName,
                fallbackSystemName: phoneIconName,
                isTemplate: !isActive,
                scale: phoneIconScale,
                accessibilityLabel: "Phone"
            )
                .foregroundStyle(phoneIconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 8) {
                Text(record.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 10) {
                    labeledValue("Port ID", record.lastAddress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rightColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var phoneIconName: String {
        isActive ? "apps.iphone.badge.checkmark" : "apps.iphone"
    }

    private var phoneIconScale: CGFloat {
        1
    }

    private var phoneIconColor: Color {
        if isActive {
            return .green
        }
        if isOnline {
            return .accentColor
        }
        return .secondary
    }

    @ViewBuilder
    private var actionButton: some View {
        if isActive {
            Button("Disconnect", action: onDisconnect)
        } else if isOnline {
            Button("Connect", action: onConnect)
        } else {
            Button("Forget", role: .destructive, action: onForget)
        }
    }

    private var rightColumn: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Last connected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(width: 148, alignment: .trailing)

            actionButton
                .frame(width: 96, alignment: .trailing)
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct TemplateResourceIcon: View {
    let name: String
    let fallbackSystemName: String
    let isTemplate: Bool
    let scale: CGFloat
    let accessibilityLabel: String

    var body: some View {
        icon
            .frame(width: 28 * scale, height: 28 * scale)
            .frame(width: 28, height: 28)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = Self.image(named: name, isTemplate: isTemplate) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(isTemplate ? .template : .original)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSystemName)
                .resizable()
                .symbolRenderingMode(.monochrome)
                .scaledToFit()
        }
    }

    private static func image(named name: String, isTemplate: Bool) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = isTemplate
        return image
    }
}
