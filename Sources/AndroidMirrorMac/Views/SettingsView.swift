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
                            PairedPhoneRow(record: record) {
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
        .frame(width: 560, height: 430)
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
}

private struct PairedPhoneRow: View {
    let record: PairedPhoneRecord
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "smartphone")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(record.lastAddress)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(record.lastConnected, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Forget", role: .destructive, action: onForget)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
