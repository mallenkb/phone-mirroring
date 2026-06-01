import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var records: [PairedPhoneRecord] {
        AppModel.recordsByMostRecent(model.pairedPhones)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(records) { record in
                            PairedPhoneRow(
                                record: record,
                                isOnline: isOnline(record)
                            ) {
                                model.forgetPairedPhone(id: record.id)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }

            Divider()

            HStack {
                Text("Clearing devices removes saved reconnect history. You will need to pair or connect again from scratch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Clear All Devices", role: .destructive) {
                    model.forgetAllPairedPhones()
                }
                .disabled(records.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: 470)
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

private struct PairedPhoneRow: View {
    let record: PairedPhoneRecord
    let isOnline: Bool
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "smartphone")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(record.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    statusPill
                    labeledValue("Port ID", record.lastAddress)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Last connected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button("Forget", role: .destructive, action: onForget)
        }
        .padding(12)
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
