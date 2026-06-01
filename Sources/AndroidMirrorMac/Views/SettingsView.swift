import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var records: [PairedPhoneRecord] {
        AppModel.recordsByMostRecent(model.pairedPhones)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            let online = isOnline(record)
                            let active = isActive(record)
                            PairedPhoneRow(
                                record: record,
                                isOnline: online,
                                isActive: active,
                                onConnect: {
                                    model.connect(record: record)
                                },
                                onDisconnect: {
                                    model.stopMirroring()
                                },
                                onForget: {
                                    model.forgetPairedPhone(id: record.id)
                                }
                            )
                        }
                    }
                }
                .frame(minHeight: 245)
            }

            notificationForwarding

            Divider()

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
        .padding(24)
        .frame(width: 660, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 28, weight: .semibold))
            Text("Manage Android devices remembered by Android Mirroring.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
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

    private var notificationForwarding: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bell.badge")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(model.experimentalADBNotificationsEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28, alignment: .top)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Experimental Android notifications")
                            .font(.system(size: 14, weight: .semibold))
                        Text(model.experimentalADBNotificationsEnabled ? "Forwarding is enabled" : "Forward Android notifications through ADB")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $model.experimentalADBNotificationsEnabled)
                        .labelsHidden()
                }

                Text("Uses ADB to poll Android notification state and repost new items as Mac notifications. Requires an authorized USB or Wireless debugging connection and may miss or redact content on some phones.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
            Image(systemName: "smartphone")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    if isActive {
                        Text("Connected")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 10) {
                    statusPill
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

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.7))
                .frame(width: 7, height: 7)
            Text(isOnline ? "Online" : "Offline")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isOnline ? Color.green : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill((isOnline ? Color.green : Color.secondary).opacity(0.12))
        )
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
