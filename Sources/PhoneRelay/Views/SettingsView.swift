import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab: SettingsTab = .devices

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case devices = "Devices"
        case mirroring = "Mirroring"
        case sharing = "Sharing"
        case shortcuts = "Shortcuts"
        case connection = "Connection"
        case about = "About"

        var id: String { rawValue }
    }

    private var records: [PairedPhoneRecord] {
        AppModel.recordsByMostRecent(model.pairedPhones)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabPicker
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            // The ScrollView spans the full width so its scroll indicator sits
            // flush against the window's right edge (the native macOS position).
            // The 24pt inset lives on the *content* instead, so the cards stay
            // padded while the bar stays at the edge.
            ScrollView {
                tabContent
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
                    .padding(.bottom, 24)
            }

            if selectedTab == .devices {
                Divider()
                clearDevicesRow
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 660, height: 600)
    }

    private var tabPicker: some View {
        CapsuleSegmentedControl(
            segments: SettingsTab.allCases.map { (value: $0, label: $0.rawValue) },
            selection: $selectedTab
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .devices:
            devicesTab
        case .mirroring:
            mirroringTab
        case .sharing:
            sharingTab
        case .shortcuts:
            shortcutsTab
        case .connection:
            connectionTab
        case .about:
            aboutTab
        }
    }

    // MARK: - Devices

    @ViewBuilder
    private var devicesTab: some View {
        if records.isEmpty {
            SettingsGroup { emptyState }
        } else {
            SettingsGroup(footnote: "Online phones reconnect automatically when this Mac is nearby.") {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { rowDivider }
                    PairedPhoneRow(
                        record: record,
                        isOnline: isOnline(record),
                        isActive: isActive(record),
                        activeADBSerial: model.selectedDevice.adbSerial,
                        liveRoutes: liveRoutes(for: record),
                        onConnect: { transport in model.connect(record: record, transport: transport.modelTransport) },
                        onDisconnect: { model.disconnectFromSettings() },
                        onUpdateWiFiIPAddress: { model.updateWiFiIPAddressFromSettings(for: record) },
                        onForget: { model.forgetPairedPhone(id: record.id) }
                    )
                }
            }
        }
    }

    private var clearDevicesRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Forgetting phones clears their reconnect history — you'll connect from scratch next time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Forget All Phones", role: .destructive) {
                model.forgetAllPairedPhones()
            }
            .buttonStyle(DestructiveSettingsButtonStyle())
            .disabled(records.isEmpty)
        }
    }

    // MARK: - Mirroring

    private var mirroringTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            qualityGroup

            SettingsGroup(title: "Display & sound") {
                toggleRow(
                    icon: "speaker.wave.2",
                    isOn: $model.mirrorAudioEnabled,
                    title: "Play phone audio on this Mac",
                    subtitle: model.mirrorAudioEnabled
                        ? "Your phone's sound comes out of this Mac while mirroring. Changing this restarts the mirror."
                        : "Your phone keeps its own sound. Changing this restarts the mirror."
                )
                rowDivider
                toggleRow(
                    icon: "display",
                    isOn: $model.mirrorScreenOffAfterThirtySecondsEnabled,
                    title: "Turn the phone screen off after 30 seconds",
                    subtitle: "If the mirror is idle, the phone's own display goes dark automatically while mirroring keeps working here. Press ⌘L to do it now."
                )
                rowDivider
                toggleRow(
                    icon: "wifi",
                    isOn: $model.backgroundWiFiHandoffEnabled,
                    title: "Advanced USB-to-Wi-Fi handoff",
                    subtitle: "Leave this off unless you want USB mirroring to prepare a separate legacy ADB Wi-Fi route."
                )
            }

            SettingsGroup(
                title: "Scrolling",
                footnote: "Applies to mouse wheel and trackpad scrolling inside the mirrored phone window."
            ) {
                scrollingPickerRow(
                    icon: "scroll",
                    title: "Scroll speed",
                    subtitle: "Controls how far the phone moves for each wheel or trackpad gesture."
                ) {
                    mirrorScrollSpeedPicker
                }

                rowDivider

                scrollingPickerRow(
                    icon: "waveform.path",
                    title: "Scroll feel",
                    subtitle: "Softens larger deltas for less jumpy motion while keeping input responsive."
                ) {
                    mirrorScrollFeelPicker
                }
            }
        }
    }

    private var qualityGroup: some View {
        SettingsGroup(
            title: "Quality",
            footnote: "Lower the resolution or bitrate for smoother mirroring on slow connections. Active mirrors restart to apply changes."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                mirrorProfilePicker

                Divider()

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
            .padding(14)
        }
    }

    // MARK: - Sharing

    private var sharingTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Between your phone and Mac") {
                toggleRow(
                    icon: "doc.on.clipboard",
                    isOn: $model.clipboardSyncEnabled,
                    title: "Share clipboard",
                    subtitle: "Copy on one device and paste on the other. Paste to the phone with ⌘V."
                )
                rowDivider
                toggleRow(
                    icon: "keyboard",
                    isOn: $model.keyboardInputEnabled,
                    title: "Type with your Mac keyboard",
                    subtitle: "Sends typing and supported shortcuts to the phone while the mirror is focused."
                )
                rowDivider
                toggleRow(
                    icon: "tray.and.arrow.down",
                    isOn: $model.dragAndDropFileTransferEnabled,
                    title: "Drag files onto the mirror",
                    subtitle: "Drop a file on the mirror to copy it to the phone's Downloads. APKs install automatically."
                )
            }

            SettingsGroup(title: "Notifications") {
                toggleRow(
                    icon: "bell.badge",
                    isOn: $model.notificationForwardingEnabled,
                    title: "Show phone notifications on this Mac",
                    subtitle: AppModel.notificationPermissionReason,
                    detail: model.notificationForwardingPermissionDenied
                        ? "macOS is blocking notifications for Phone Relay. Turn it on in System Settings, then switch this on again."
                        : "Group summaries and ongoing items (music, navigation) are skipped. macOS asks permission the first time."
                )

                if model.notificationForwardingPermissionDenied {
                    rowDivider
                    HStack {
                        Spacer()
                        Button("Open Notification Settings") {
                            model.openNotificationSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                if model.notificationForwardingEnabled, !model.notificationForwardingPermissionDenied {
                    rowDivider
                    toggleRow(
                        icon: "lock.shield",
                        isOn: $model.notificationSuppressSecurityCodesEnabled,
                        title: "Hide one-time codes",
                        subtitle: "Don't forward 2FA / verification-code notifications to this Mac."
                    )
                    rowDivider
                    toggleRow(
                        icon: "eye.slash",
                        isOn: $model.notificationHideBodyEnabled,
                        title: "Hide message previews",
                        subtitle: "Show the app and sender, but not the message text."
                    )
                    rowDivider
                    toggleRow(
                        icon: "record.circle",
                        isOn: $model.notificationPauseWhileRecordingEnabled,
                        title: "Pause while recording",
                        subtitle: "Stop forwarding notifications while you're recording the phone."
                    )
                }
            }

            if model.notificationForwardingEnabled,
               !model.notificationForwardingPermissionDenied,
               !model.knownNotificationApps.isEmpty {
                SettingsGroup(
                    title: "Apps",
                    footnote: "Turn off an app to stop its notifications from reaching this Mac."
                ) {
                    ForEach(Array(model.knownNotificationApps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { rowDivider }
                        notificationAppRow(app)
                    }
                }
            }

            SettingsGroup(
                title: "Saved files",
                footnote: "Where Phone Relay saves screenshots and screen recordings. Defaults to Downloads."
            ) {
                captureFolderRow(
                    title: "Screenshots",
                    path: model.screenshotFolderPath,
                    chooseAction: model.chooseScreenshotFolder,
                    resetAction: model.resetScreenshotFolder
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                rowDivider

                captureFolderRow(
                    title: "Screen recordings",
                    path: model.recordingFolderPath,
                    chooseAction: model.chooseRecordingFolder,
                    resetAction: model.resetRecordingFolder
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                rowDivider

                scrollingPickerRow(
                    icon: "timer",
                    title: "Recording length",
                    subtitle: "Maximum length per recording. Phones on Android 11+ honor longer limits; older phones stop at 3 minutes."
                ) {
                    recordingLengthPicker
                }
            }
        }
    }

    private var recordingLengthPicker: some View {
        Picker("", selection: $model.recordingMaxMinutes) {
            ForEach([3, 5, 10, 15, 30, 60, 120, 180], id: \.self) { value in
                Text(Self.recordingLengthLabel(minutes: value)).tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 116, alignment: .leading)
    }

    static func recordingLengthLabel(minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(minutes) min"
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(KeyboardShortcutsCatalog.groups, id: \.title) { group in
                SettingsGroup(title: group.title) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { rowDivider }
                        shortcutRow(keys: item.keys, action: item.action)
                    }
                }
            }
        }
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(keys)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 120, alignment: .leading)
            Text(action)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Connection

    private var connectionTab: some View {
        let snapshot = model.connectionHealthSnapshot
        // Grouped for top-down diagnosis: the live connection first, then each
        // transport's availability, then the macOS services both depend on.
        let categories: [(title: String, items: [ConnectionHealthSnapshot.Item])] = [
            ("Connection", [snapshot.selectedTransport, snapshot.reconnectAttempts]),
            ("Transports", [snapshot.usbAuthorization, snapshot.wifiReachability, snapshot.wifiHandoff]),
            ("System", [snapshot.adbStatus, snapshot.localNetworkPermission])
        ]

        return SettingsGroup(
            title: "Connection health",
            footnote: "Live status for the active connection, each transport, and the macOS services they depend on."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(categories, id: \.title) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10, alignment: .top),
                                GridItem(.flexible(), spacing: 10, alignment: .top)
                            ],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(category.items) { item in
                                connectionHealthMetric(item)
                            }
                        }
                    }
                }

                // Only surface the fix row when there's actually something to do.
                // When the device is reachable it's just noise, so hide it; when
                // Local Network is the blocker it carries a one-tap CTA to grant it.
                if snapshot.recommendedFix != AppModel.noActionNeededRecommendedFix {
                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22, alignment: .center)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Next recommended fix")
                                .font(.system(size: 13, weight: .semibold))
                            Text(snapshot.recommendedFix)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if snapshot.recommendedFix == AppModel.localNetworkRecommendedFix {
                            Button("Open Local Network") {
                                model.openLocalNetworkSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func connectionHealthMetric(_ item: ConnectionHealthSnapshot.Item) -> some View {
        let color = connectionHealthColor(item.level)
        let needsAttention = item.level == .warning || item.level == .issue
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: connectionHealthIcon(item.id))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    needsAttention ? color.opacity(0.5) : Color.secondary.opacity(0.14),
                    lineWidth: 1
                )
        )
    }

    /// Maps each health item to an identifying SF Symbol so the indicators are
    /// scannable at a glance; the symbol is tinted by the item's health level.
    private func connectionHealthIcon(_ id: String) -> String {
        switch id {
        case "transport": return "arrow.left.arrow.right"
        case "attempts": return "arrow.clockwise"
        case "usb": return "cable.connector"
        case "wifi": return "wifi"
        case "wifi-handoff": return "arrow.triangle.2.circlepath"
        case "adb": return "terminal"
        case "local-network": return "lock.shield"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    private func connectionHealthColor(_ level: ConnectionHealthSnapshot.Level) -> Color {
        switch level {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .issue:
            return .red
        case .neutral:
            return .secondary
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            aboutIdentityGroup

            SettingsGroup(title: "Privacy Policy") {
                aboutBlock(
                    note: "Shown in-app so the policy stays readable without opening a browser.",
                    body: AboutContent.privacyPolicy
                )
            }

            SettingsGroup(title: "Support") {
                aboutBlock(
                    note: "These details help diagnose setup, pairing, and mirroring issues.",
                    body: AboutContent.supportDetails
                )
            }

            SettingsGroup(title: "Legal") {
                VStack(alignment: .leading, spacing: 12) {
                    aboutTextBlock(title: "Open Source License", AboutContent.projectLicense)
                    Divider()
                    aboutTextBlock(title: "Third-Party Notices", AboutContent.thirdPartyNotices)
                }
                .padding(14)
            }
        }
    }

    private var aboutIdentityGroup: some View {
        SettingsGroup {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone Relay")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Local-first Android mirroring for macOS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        labeledBadge("Version", bundleVersion)
                        labeledBadge("Build", bundleBuild)
                        labeledBadge("Bundle ID", bundleIdentifier)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    private func aboutBlock(note: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            aboutTextBlock(body)
        }
        .padding(14)
    }

    private func captureFolderRow(
        title: String,
        path: String?,
        chooseAction: @escaping () -> Void,
        resetAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(pathDisplay(path))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Choose…", action: chooseAction)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Reset", action: resetAction)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(path == nil)
        }
    }

    private func pathDisplay(_ path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "~/\(MediaCaptureService.outputFolderName)"
        }
        return (path as NSString).abbreviatingWithTildeInPath
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2"
    }

    private var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "8"
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

    // MARK: - Shared rows

    private func rowIcon(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(width: 26, alignment: .center)
    }

    private func toggleRow(
        icon: String,
        isOn: Binding<Bool>,
        title: String,
        subtitle: String,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                rowIcon(icon, active: isOn.wrappedValue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// One app in the per-app mute list. The switch reads as "forward this app",
    /// so on = delivered, off = muted.
    private func notificationAppRow(_ app: NotificationAppInfo) -> some View {
        let isForwarded = Binding(
            get: { !model.isNotificationPackageMuted(app.package) },
            set: { model.setNotificationPackage(app.package, muted: !$0) }
        )
        return HStack(alignment: .center, spacing: 14) {
            rowIcon("app.badge", active: isForwarded.wrappedValue)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(app.package)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            Toggle(app.label, isOn: isForwarded)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider()
    }

    // MARK: - Quality controls

    private var mirrorProfilePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Mirror profiles".uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Presets apply resolution, bitrate, frame rate, and audio together.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 10, alignment: .top)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(MirrorProfile.allCases) { profile in
                    mirrorProfileCard(profile)
                }
            }
        }
    }

    private func mirrorProfileCard(_ profile: MirrorProfile) -> some View {
        let isSelected = model.selectedMirrorProfile == profile
        return Button {
            model.selectedMirrorProfile = profile
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 6) {
                    Text(profile.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(profile.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(profile.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.18), lineWidth: isSelected ? 1.25 : 1)
            )
        }
        .buttonStyle(.plain)
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

    private var mirrorScrollSpeedPicker: some View {
        Picker("", selection: $model.mirrorScrollSpeedPercent) {
            Text("Slow").tag(10)
            Text("Normal").tag(20)
            Text("Fast").tag(35)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var mirrorScrollFeelPicker: some View {
        Picker("", selection: $model.mirrorScrollFeel) {
            ForEach(MirrorScrollFeel.allCases) { feel in
                Text(feel.title).tag(feel)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func scrollingPickerRow<Control: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            rowIcon(icon, active: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The flexible label column above pushes the control to the trailing
            // edge; each control sizes to its own content, so every scrolling
            // row's segmented control shares the same right edge — flush with the
            // card's padding — instead of floating mid-row at different widths.
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No remembered phones")
                .font(.headline)
            Text("Phones appear here after you connect or pair them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.vertical, 12)
    }

    // MARK: - Device state

    private func isOnline(_ record: PairedPhoneRecord) -> Bool {
        if model.isSelectedDeviceOnline,
           recordMatchesSelectedDevice(record) {
            return true
        }

        return liveRoutes(for: record).hasWiFi
    }

    private func liveRoutes(for record: PairedPhoneRecord) -> AppModel.LiveConnectionRoutes {
        AppModel.liveConnectionRoutes(
            for: record,
            authorizedDevices: model.latestAuthorizedADBDevices,
            discoveredPhones: model.discoveredPhones
        )
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

// MARK: - Settings group container

/// The macOS System Settings look: an optional section title, a rounded card
/// holding rows separated by hairline dividers, and an optional footnote below.
/// Replaces the card styling that used to be copy-pasted into every section.
private struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
    }
}

/// Modern macOS capsule segmented control: a recessed track holding a single
/// elevated pill that springs between segments. Unlike the stock `.segmented`
/// `Picker`, there are **no separators between items** — matching the design
/// spec. The pill slides via `matchedGeometryEffect`, and the spring keeps it
/// consistent with the app's premium motion.
private struct CapsuleSegmentedControl<Value: Hashable>: View {
    let segments: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var scheme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.value) { segment in
                segmentButton(value: segment.value, label: segment.label)
            }
        }
        // Scope the spring to THIS control's subtree. Using `withAnimation` at
        // the tap site instead would animate everything bound to the selection —
        // including the tab-content swap — and animating the About tab's
        // selectable text blocks inside the ScrollView hangs the app. Here only
        // the pill's matchedGeometryEffect rides the spring; the content swaps
        // instantly.
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.06))
        )
    }

    private func segmentButton(value: Value, label: String) -> some View {
        let isSelected = value == selection
        return Button {
            guard value != selection else { return }
            selection = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Capsule())
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "segmentPill", in: namespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

/// Bordered, low-emphasis button (e.g. the "more actions" ellipsis): a faint
/// translucent fill plus a hairline border, distinct from the filled primary.
private struct SettingsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// One row of the custom "more actions" dropdown. Renders its own hover
/// highlight (accent for normal rows, red for destructive) so it can show a
/// red "Forget" that a native NSMenu item can't.
private struct MoreMenuRow: View {
    let title: String
    var subtitle: String?
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(foreground)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(subtitleForeground)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, subtitle == nil ? 6 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? highlight : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        if isDestructive { return isHovering ? .white : .red }
        return isHovering ? .white : .primary
    }

    private var subtitleForeground: Color {
        isHovering ? .white.opacity(0.78) : .secondary
    }

    private var highlight: Color {
        isDestructive ? Color.red : Color.accentColor
    }
}

private struct SettingsRowActionButtonStyle: ButtonStyle {
    static let width: CGFloat = 96
    static let height: CGFloat = 28

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let foreground = isEnabled ? Color.red : Color.secondary
        let background = isEnabled ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12)

        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 13)
            .frame(minWidth: Self.width)
            .frame(height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background.opacity(configuration.isPressed ? 1.35 : 1))
            )
    }
}

enum SettingsDeviceTransport: String, CaseIterable, Identifiable {
    case wifi
    case usb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .usb: return "USB"
        }
    }

    var connectTitle: String {
        "Connect \(title)"
    }

    var connectSubtitle: String {
        switch self {
        case .wifi: return "No cable. Same Wi-Fi network."
        case .usb: return "Fastest and most reliable."
        }
    }

    var modelTransport: AppModel.SavedConnectionTransport {
        switch self {
        case .wifi: return .wifi
        case .usb: return .usb
        }
    }
}

private struct PairedPhoneRow: View {
    let record: PairedPhoneRecord
    let isOnline: Bool
    let isActive: Bool
    let activeADBSerial: String?
    let liveRoutes: AppModel.LiveConnectionRoutes
    let onConnect: (SettingsDeviceTransport) -> Void
    let onDisconnect: () -> Void
    let onUpdateWiFiIPAddress: () -> Void
    let onForget: () -> Void
    @State private var showMoreMenu = false

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
                    .frame(maxWidth: .infinity, alignment: .leading)

                connectionDetails
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rightColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
    private var actionButtons: some View {
        if isActive {
            // Connected: disconnecting is the only action — a connect control
            // would be redundant, so it's hidden until the device is offline.
            Button("Disconnect", action: onDisconnect)
                .buttonStyle(SettingsRowActionButtonStyle())
        } else {
            moreActionsMenu
        }
    }

    private var moreActionsMenu: some View {
        Button {
            showMoreMenu.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(SettingsSecondaryButtonStyle())
        // A native Menu (NSMenu) ignores per-item colors, so the destructive
        // "Forget" can't render red. A popover with custom rows can, and it
        // isn't clipped by the surrounding ScrollView the way an overlay is.
        .popover(isPresented: $showMoreMenu, arrowEdge: .bottom) {
            moreActionsDropdown
        }
        .help("More actions")
    }

    private var moreActionsDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(availableTransports) { transport in
                MoreMenuRow(
                    title: transport.connectTitle,
                    subtitle: transport.connectSubtitle
                ) {
                    showMoreMenu = false
                    onConnect(transport)
                }
            }

            if !availableTransports.isEmpty {
                Divider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }

            MoreMenuRow(
                title: "Update Wi-Fi IP Address",
                subtitle: "Enter a new IP\nor connect USB to refresh it."
            ) {
                showMoreMenu = false
                onUpdateWiFiIPAddress()
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)

            MoreMenuRow(title: "Forget", isDestructive: true) {
                showMoreMenu = false
                onForget()
            }
        }
        .padding(5)
        .frame(width: 260)
    }

    private var rightColumn: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                Text(record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(width: 148, alignment: .trailing)

            actionButtons
                .fixedSize(horizontal: true, vertical: false)
                .frame(alignment: .trailing)
        }
    }

    private var statusLabel: String {
        if let activeTransport {
            return "Connected via \(activeTransport.title)"
        }
        if isActive { return "Connected" }
        if let status = liveRoutes.statusLabel { return status }
        if isOnline { return "Online" }
        return "Last seen"
    }

    private var activeTransport: SettingsDeviceTransport? {
        guard isActive, let activeADBSerial else { return nil }
        if let usbAddress = liveRoutes.usbSerial ?? record.resolvedUSBSerial,
           activeADBSerial == usbAddress {
            return .usb
        }
        if let wifiAddress,
           activeADBSerial == wifiAddress {
            return .wifi
        }
        if PairedPhoneRecord.isWirelessADBAddress(activeADBSerial) {
            return .wifi
        }
        return .usb
    }

    private var statusColor: Color {
        if isActive { return .green }
        if isOnline { return .accentColor }
        return .secondary
    }

    private var connectionDetails: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
            connectionDetailRow("USB", usbAddress ?? "N/A")
            connectionDetailRow("Wi-Fi", wifiAddress ?? "N/A")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func connectionDetailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text("\(label):")
                .fontWeight(.medium)
                .gridColumnAlignment(.leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usbAddress: String? {
        record.resolvedUSBSerial
    }

    private var wifiAddress: String? {
        liveRoutes.wifiAddress ?? record.resolvedWiFiAddress
    }

    private var availableTransports: [SettingsDeviceTransport] {
        SettingsDeviceTransport.allCases.filter { transport in
            switch transport {
            case .wifi:
                return wifiAddress != nil
            case .usb:
                return usbAddress != nil
            }
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
