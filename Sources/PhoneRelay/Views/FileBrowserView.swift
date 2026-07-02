import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State for the Phone Files window. All PhoneFileBrowserService calls are
/// blocking adb invocations and run through detached Tasks; results hop back
/// to the main actor and are dropped if the user has navigated away since.
@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var path = PhoneFileBrowserService.defaultRoot
    @Published private(set) var entries: [PhoneFileEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var storage: PhoneStorageInfo?
    /// Non-nil while a push/pull/delete runs; the UI overlays this label and
    /// blocks further operations so transfers stay strictly sequential.
    @Published private(set) var activityText: String?
    @Published var errorMessage: String?

    /// Called on the main actor only; AppDelegate injects the live AppModel
    /// serial so the window always follows the currently connected phone.
    private let serialProvider: () -> String?
    private var loadGeneration = 0

    init(serialProvider: @escaping () -> String?) {
        self.serialProvider = serialProvider
    }

    var canGoBack: Bool {
        PhoneFileBrowserService.parent(of: path) != nil
    }

    var displayPath: String {
        let pretty = path.replacingOccurrences(of: "/sdcard", with: "Internal storage")
        return pretty
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: " › ")
    }

    var storageSummary: String? {
        guard let storage else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: storage.freeBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: storage.totalBytes, countStyle: .file)
        return "\(free) free of \(total)"
    }

    var isBusy: Bool { activityText != nil }

    private var serialOrExplain: String? {
        guard let serial = serialProvider(), !serial.isEmpty else {
            entries = []
            storage = nil
            errorMessage = "Connect a phone to browse its files."
            return nil
        }
        return serial
    }

    func refresh() {
        guard let serial = serialOrExplain else { return }
        errorMessage = nil
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        let target = path
        Task.detached(priority: .userInitiated) { [weak self] in
            let listing = PhoneFileBrowserService.listDirectory(serial: serial, path: target)
            let storage = PhoneFileBrowserService.storageInfo(serial: serial, path: target)
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.isLoading = false
                self.storage = storage
                switch listing {
                case .success(let result):
                    self.entries = result.entries
                case .failure(let error):
                    self.entries = []
                    self.errorMessage = error.message
                }
            }
        }
    }

    func open(_ entry: PhoneFileEntry) {
        guard !isBusy else { return }
        guard entry.isNavigable else {
            openFile(entry)
            return
        }
        path = PhoneFileBrowserService.joined(path, entry.name)
        entries = []
        refresh()
    }

    /// Pulls a file into a throwaway temp folder and hands it to the default
    /// app. Each open gets a fresh UUID directory so stale copies of a
    /// changed phone file can't shadow the new pull.
    private func openFile(_ entry: PhoneFileEntry) {
        guard let serial = serialOrExplain else { return }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        activityText = "Opening — \(entry.name)"
        Task.detached { [weak self] in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhoneRelay Files", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let result: Result<URL, PhoneFileBrowserService.ServiceError>
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                result = PhoneFileBrowserService.pull(
                    serial: serial, remotePath: remotePath, localDirectory: directory
                )
            } catch {
                result = .failure(.operationFailed(error.localizedDescription))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activityText = nil
                switch result {
                case .success(let localURL):
                    NSWorkspace.shared.open(localURL)
                case .failure(let error):
                    self.errorMessage = "Couldn't open \(entry.name): \(error.message)"
                }
            }
        }
    }

    func goBack() {
        guard !isBusy, let parent = PhoneFileBrowserService.parent(of: path) else { return }
        path = parent
        entries = []
        refresh()
    }

    /// Pulls a file or folder into ~/Downloads and reveals it in Finder.
    func download(_ entry: PhoneFileEntry) {
        guard let serial = serialOrExplain, !isBusy else { return }
        guard let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first else {
            errorMessage = "Couldn't find your Downloads folder."
            return
        }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        activityText = "Copying to Mac — \(entry.name)"
        Task.detached { [weak self] in
            let result = PhoneFileBrowserService.pull(
                serial: serial, remotePath: remotePath, localDirectory: downloads
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activityText = nil
                switch result {
                case .success(let localURL):
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                case .failure(let error):
                    self.errorMessage = "Couldn't copy \(entry.name): \(error.message)"
                }
            }
        }
    }

    /// Pushes dropped Mac files into the current folder, one at a time.
    func pushFiles(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard let serial = serialOrExplain, !fileURLs.isEmpty, !isBusy else { return }
        let destination = path
        Task { [weak self] in
            var failure: String?
            for (index, url) in fileURLs.enumerated() where failure == nil {
                let name = url.lastPathComponent
                self?.activityText = fileURLs.count == 1
                    ? "Copying to phone — \(name)"
                    : "Copying to phone — \(index + 1) of \(fileURLs.count) · \(name)"
                let outcome = await Task.detached {
                    PhoneFileBrowserService.push(
                        serial: serial, localPath: url.path, remoteDirectory: destination
                    )
                }.value
                if !outcome.succeeded { failure = outcome.message }
            }
            await Task.detached {
                PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: destination)
            }.value
            guard let self else { return }
            self.activityText = nil
            if let failure {
                self.errorMessage = "Couldn't copy to the phone: \(failure)"
            }
            self.refresh()
        }
    }

    func delete(_ entry: PhoneFileEntry) {
        guard let serial = serialOrExplain, !isBusy else { return }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        let isDirectory = entry.isNavigable
        activityText = "Deleting — \(entry.name)"
        Task.detached { [weak self] in
            let outcome = PhoneFileBrowserService.delete(
                serial: serial, remotePath: remotePath, isDirectory: isDirectory
            )
            if outcome.succeeded {
                PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: remotePath)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activityText = nil
                if !outcome.succeeded {
                    self.errorMessage = "Couldn't delete \(entry.name): \(outcome.message)"
                }
                self.refresh()
            }
        }
    }

    func rename(_ entry: PhoneFileEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let serial = serialOrExplain, !isBusy,
              !trimmed.isEmpty, trimmed != entry.name
        else { return }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        activityText = "Renaming — \(entry.name)"
        Task.detached { [weak self] in
            let outcome = PhoneFileBrowserService.rename(
                serial: serial, remotePath: remotePath, to: trimmed
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activityText = nil
                if !outcome.succeeded {
                    self.errorMessage = "Couldn't rename \(entry.name): \(outcome.message)"
                }
                self.refresh()
            }
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let serial = serialOrExplain, !isBusy, !trimmed.isEmpty else { return }
        let parentPath = path
        activityText = "Creating folder — \(trimmed)"
        Task.detached { [weak self] in
            let outcome = PhoneFileBrowserService.makeDirectory(
                serial: serial, parentPath: parentPath, name: trimmed
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activityText = nil
                if !outcome.succeeded {
                    self.errorMessage = "Couldn't create the folder: \(outcome.message)"
                }
                self.refresh()
            }
        }
    }
}

/// Finder-style browser for the connected phone's shared storage.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel

    @State private var isDropTargeted = false
    @State private var entryToDelete: PhoneFileEntry?
    @State private var entryToRename: PhoneFileEntry?
    @State private var renameText = ""
    @State private var isNamingFolder = false
    @State private var newFolderText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = model.errorMessage {
                errorBanner(message)
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { model.refresh() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .alert(
            "Delete \"\(entryToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete { model.delete(entry) }
                entryToDelete = nil
            }
            Button("Cancel", role: .cancel) { entryToDelete = nil }
        } message: {
            Text("This removes it from the phone. You can't undo this.")
        }
        .alert(
            "Rename \"\(entryToRename?.name ?? "")\"",
            isPresented: Binding(
                get: { entryToRename != nil },
                set: { if !$0 { entryToRename = nil } }
            )
        ) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let entry = entryToRename { model.rename(entry, to: renameText) }
                entryToRename = nil
            }
            Button("Cancel", role: .cancel) { entryToRename = nil }
        }
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Folder name", text: $newFolderText)
            Button("Create") {
                model.createFolder(named: newFolderText)
                isNamingFolder = false
            }
            Button("Cancel", role: .cancel) { isNamingFolder = false }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack || model.isBusy)
            .help("Back")

            Text(model.displayPath)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if let summary = model.storageSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                newFolderText = ""
                isNamingFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(model.isBusy)
            .help("New folder")

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isBusy)
            .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if model.isLoading && model.entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty {
                Text(model.errorMessage == nil ? "This folder is empty." : "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { entry in
                    FileBrowserRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(entry) }
                        .contextMenu {
                            Button("Open") { model.open(entry) }
                            Button("Save to Mac") { model.download(entry) }
                            Button("Rename…") {
                                renameText = entry.name
                                entryToRename = entry
                            }
                            Divider()
                            Button(role: .destructive) {
                                entryToDelete = entry
                            } label: {
                                // Plain foregroundColor is stripped inside
                                // menus; the attributed color survives, so
                                // Delete reads red even where the destructive
                                // role isn't tinted.
                                Text(redMenuTitle("Delete…"))
                            }
                        }
                }
                .listStyle(.inset)
            }

            if let activity = model.activityText {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(activity)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
    }

    private var footer: some View {
        Text("Drop files here to copy them to this folder")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    private func redMenuTitle(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        text.foregroundColor = .red
        return text
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = DroppedURLCollector()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.append(url)
                } else if let url = item as? URL {
                    collector.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak model] in
            model?.pushFiles(collector.urls)
        }
        return true
    }
}

/// NSItemProvider completion handlers arrive on arbitrary queues; this box
/// serializes the collected URLs until the DispatchGroup drains.
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct FileBrowserRow: View {
    let entry: PhoneFileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(entry.isNavigable ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.isNavigable ? "—" : PhoneFileBrowserService.formattedSize(entry.sizeBytes))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(entry.modifiedText)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.vertical, 2)
    }

    private var iconName: String {
        guard !entry.isNavigable else { return "folder" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp":
            return "photo"
        case "mp4", "mov", "mkv", "webm", "3gp", "m4v":
            return "film"
        case "mp3", "m4a", "ogg", "opus", "flac", "wav", "aac":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz":
            return "doc.zipper"
        case "apk":
            return "shippingbox"
        default:
            return "doc"
        }
    }
}
