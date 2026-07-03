import AppKit
import CoreTransferable
import Quartz
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Internal pasteboard type for drags between Phone Files rows.
    static let phoneRelayEntry = UTType(exportedAs: "com.phonerelay.phone-entry")
}

/// Drag payload for a phone entry. The codable form powers in-window moves;
/// the file representation lazily pulls the entry so drags into Finder (or
/// any app) receive a real file promise.
struct PhoneEntryTransfer: Codable, Transferable {
    var serial: String
    var remotePath: String
    var isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .phoneRelayEntry)
        FileRepresentation(exportedContentType: .item) { transfer in
            let directory = try PhoneFileBrowserService.makeTemporaryPullDirectory()
            switch PhoneFileBrowserService.pull(
                serial: transfer.serial,
                remotePath: transfer.remotePath,
                localDirectory: directory
            ) {
            case .success(let url):
                return SentTransferredFile(url, allowAccessingOriginalFile: true)
            case .failure(let error):
                throw NSError(domain: "PhoneEntryTransfer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: error.message
                ])
            }
        }
    }
}

struct FileTransferActivity: Equatable {
    var title: String
    var detail: String
    var progress: Double?
}

/// State for the Phone Files window. All PhoneFileBrowserService calls are
/// blocking adb invocations and run through detached Tasks; results hop back
/// to the main actor and are dropped if the user has navigated away since.
@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var path = PhoneFileBrowserService.defaultRoot
    @Published private(set) var entries: [PhoneFileEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var storage: PhoneStorageInfo?
    /// Non-nil while a push/pull/delete runs; the UI overlays progress and
    /// blocks further operations so transfers stay strictly sequential.
    @Published private(set) var activity: FileTransferActivity?
    @Published var errorMessage: String?

    /// Called on the main actor only; AppDelegate injects the live AppModel
    /// serial so the window always follows the currently connected phone.
    private let serialProvider: () -> String?
    private var loadGeneration = 0
    private var quickLookController: FileQuickLookController?

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

    var isBusy: Bool { activity != nil }

    enum SortField {
        case name, size, modified
    }

    enum ViewMode {
        case list, gallery
    }

    @Published var viewMode: ViewMode = .list

    /// Blocking thumbnail fetch for gallery cells; call from a detached task.
    nonisolated func loadThumbnail(directory: String, entry: PhoneFileEntry, serial: String) -> NSImage? {
        PhoneThumbnailStore.shared.thumbnail(
            serial: serial, directory: directory, entry: entry
        )
    }

    var thumbnailContext: (serial: String, directory: String)? {
        guard let serial = serialProvider(), !serial.isEmpty else { return nil }
        return (serial, path)
    }

    @Published private(set) var sortField: SortField = .name
    @Published private(set) var sortAscending = true

    /// Folders always group above files (like Finder's folders-first
    /// preference); the chosen field orders within each group.
    var sortedEntries: [PhoneFileEntry] {
        entries.sorted { a, b in
            if a.isNavigable != b.isNavigable { return a.isNavigable }
            let ordered: Bool
            switch sortField {
            case .name:
                ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                ordered = (a.sizeBytes ?? -1) < (b.sizeBytes ?? -1)
            case .modified:
                ordered = a.modifiedText < b.modifiedText
            }
            return sortAscending ? ordered : !ordered
        }
    }

    func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field == .name
        }
    }

    private var serialOrExplain: String? {
        guard let serial = serialProvider(), !serial.isEmpty else {
            entries = []
            storage = nil
            errorMessage = "Connect a phone to browse its files."
            return nil
        }
        return serial
    }

    private func beginActivity(title: String, detail: String, progress: Double? = nil) {
        activity = FileTransferActivity(title: title, detail: detail, progress: progress)
    }

    private func updateActivity(detail: String, progress: Double? = nil) {
        guard var current = activity else { return }
        current.detail = detail
        current.progress = progress
        activity = current
    }

    private func finishActivity() {
        activity = nil
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

    func preview(_ entry: PhoneFileEntry) {
        guard let serial = serialOrExplain, !isBusy else { return }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        beginActivity(title: "Preparing preview", detail: entry.name)
        Task.detached { [weak self] in
            let result = Self.pullToTemporaryURL(serial: serial, remotePath: remotePath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishActivity()
                switch result {
                case .success(let localURL):
                    self.showQuickLook(url: localURL)
                case .failure(let error):
                    self.errorMessage = "Couldn't preview \(entry.name): \(error.message)"
                }
            }
        }
    }

    /// Pulls a file into a throwaway temp folder and hands it to the default
    /// app. Each open gets a fresh UUID directory so stale copies of a
    /// changed phone file can't shadow the new pull.
    private func openFile(_ entry: PhoneFileEntry) {
        guard let serial = serialOrExplain else { return }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        beginActivity(title: "Opening from phone", detail: entry.name)
        Task.detached { [weak self] in
            let result = Self.pullToTemporaryURL(serial: serial, remotePath: remotePath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishActivity()
                switch result {
                case .success(let localURL):
                    NSWorkspace.shared.open(localURL)
                case .failure(let error):
                    self.errorMessage = "Couldn't open \(entry.name): \(error.message)"
                }
            }
        }
    }

    private nonisolated static func pullToTemporaryURL(
        serial: String,
        remotePath: String
    ) -> Result<URL, PhoneFileBrowserService.ServiceError> {
        do {
            let directory = try PhoneFileBrowserService.makeTemporaryPullDirectory()
            return PhoneFileBrowserService.pull(
                serial: serial, remotePath: remotePath, localDirectory: directory
            )
        } catch {
            return .failure(.operationFailed(error.localizedDescription))
        }
    }

    private func showQuickLook(url: URL) {
        let controller = FileQuickLookController(url: url)
        quickLookController = controller
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = controller
        panel.delegate = controller
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func goBack() {
        guard !isBusy, let parent = PhoneFileBrowserService.parent(of: path) else { return }
        path = parent
        entries = []
        refresh()
    }

    func download(_ entry: PhoneFileEntry) {
        download([entry])
    }

    /// Pulls files or folders into ~/Downloads, one at a time, then reveals
    /// them in Finder. Stops at the first failure but still reveals whatever
    /// already copied.
    func download(_ entriesToDownload: [PhoneFileEntry]) {
        guard let serial = serialOrExplain, !isBusy, !entriesToDownload.isEmpty else { return }
        guard let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first else {
            errorMessage = "Couldn't find your Downloads folder."
            return
        }
        let directory = path
        let items = entriesToDownload.map { entry in
            (name: entry.name, remotePath: PhoneFileBrowserService.joined(directory, entry.name))
        }
        Task { [weak self] in
            var savedURLs: [URL] = []
            var failure: String?
            let total = items.count
            for (index, item) in items.enumerated() where failure == nil {
                self?.beginActivity(
                    title: "Copying from phone",
                    detail: total == 1 ? item.name : "\(index + 1) of \(total) - \(item.name)",
                    progress: total == 1 ? nil : Double(index) / Double(total)
                )
                let result = await Task.detached {
                    PhoneFileBrowserService.pull(
                        serial: serial, remotePath: item.remotePath, localDirectory: downloads
                    )
                }.value
                switch result {
                case .success(let localURL):
                    savedURLs.append(localURL)
                case .failure(let error):
                    failure = "Couldn't copy \(item.name): \(error.message)"
                }
            }
            guard let self else { return }
            self.finishActivity()
            if let failure {
                self.errorMessage = failure
            }
            if !savedURLs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
            }
        }
    }

    /// Pushes dropped Mac files into the current folder, one at a time.
    func pushFiles(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard let serial = serialOrExplain, !fileURLs.isEmpty, !isBusy else { return }
        pushFiles(fileURLs, serial: serial, destination: path)
    }

    private func pushFiles(_ fileURLs: [URL], serial: String, destination: String) {
        Task { [weak self] in
            var failure: String?
            let total = fileURLs.count
            for (index, url) in fileURLs.enumerated() where failure == nil {
                let name = url.lastPathComponent
                let detail = total == 1
                    ? name
                    : "\(index + 1) of \(total) - \(name)"
                self?.beginActivity(
                    title: "Copying to phone",
                    detail: detail,
                    progress: total == 1 ? nil : Double(index) / Double(total)
                )
                let outcome = await Task.detached {
                    PhoneFileBrowserService.push(
                        serial: serial, localPath: url.path, remoteDirectory: destination
                    )
                }.value
                if !outcome.succeeded { failure = outcome.message }
                if failure == nil, total > 1 {
                    self?.updateActivity(
                        detail: detail,
                        progress: Double(index + 1) / Double(total)
                    )
                }
            }
            await Task.detached {
                PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: destination)
            }.value
            guard let self else { return }
            self.finishActivity()
            if let failure {
                self.errorMessage = "Couldn't copy to the phone: \(failure)"
            }
            self.refresh()
        }
    }

    func dragPayload(for entry: PhoneFileEntry) -> PhoneEntryTransfer {
        PhoneEntryTransfer(
            serial: serialProvider() ?? "",
            remotePath: PhoneFileBrowserService.joined(path, entry.name),
            isDirectory: entry.isNavigable
        )
    }

    func dragItemProvider(for entry: PhoneFileEntry) -> NSItemProvider {
        let transfer = dragPayload(for: entry)
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(transfer) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.phoneRelayEntry.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        provider.suggestedName = entry.name
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.item.identifier,
            fileOptions: entry.isNavigable ? [.openInPlace] : [],
            visibility: .all
        ) { completion in
            do {
                let directory = try PhoneFileBrowserService.makeTemporaryPullDirectory()
                switch PhoneFileBrowserService.pull(
                    serial: transfer.serial,
                    remotePath: transfer.remotePath,
                    localDirectory: directory
                ) {
                case .success(let url):
                    completion(url, true, nil)
                case .failure(let error):
                    completion(nil, false, NSError(domain: "PhoneEntryTransfer", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: error.message
                    ]))
                }
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    /// In-window drop of a row onto a folder row: move, or copy with option.
    func relocate(_ transfer: PhoneEntryTransfer, into folder: PhoneFileEntry, copy: Bool) {
        guard let serial = serialOrExplain, !isBusy else { return }
        let destination = PhoneFileBrowserService.joined(path, folder.name)
        guard destination != (transfer.remotePath as NSString).deletingLastPathComponent
            || copy
        else { return }
        let name = (transfer.remotePath as NSString).lastPathComponent
        beginActivity(
            title: copy ? "Copying on phone" : "Moving on phone",
            detail: name
        )
        Task.detached { [weak self] in
            let outcome = PhoneFileBrowserService.relocate(
                serial: serial,
                remotePath: transfer.remotePath,
                intoDirectory: destination,
                copy: copy
            )
            if outcome.succeeded {
                PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: destination)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishActivity()
                if !outcome.succeeded {
                    self.errorMessage = "Couldn't \(copy ? "copy" : "move") \(name): \(outcome.message)"
                }
                self.refresh()
            }
        }
    }

    /// External files dropped directly onto a folder row.
    func pushFiles(_ urls: [URL], intoSubfolder folder: PhoneFileEntry) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard let serial = serialOrExplain, !fileURLs.isEmpty, !isBusy else { return }
        let destination = PhoneFileBrowserService.joined(path, folder.name)
        pushFiles(fileURLs, serial: serial, destination: destination)
    }

    func delete(_ entry: PhoneFileEntry) {
        delete([entry])
    }

    /// Deletes entries one at a time behind a single activity overlay,
    /// stopping at the first failure, then refreshes once.
    func delete(_ entriesToDelete: [PhoneFileEntry]) {
        guard let serial = serialOrExplain, !isBusy, !entriesToDelete.isEmpty else { return }
        let directory = path
        let items = entriesToDelete.map { entry in
            (
                name: entry.name,
                remotePath: PhoneFileBrowserService.joined(directory, entry.name),
                isDirectory: entry.isNavigable
            )
        }
        Task { [weak self] in
            var failure: String?
            let total = items.count
            for (index, item) in items.enumerated() where failure == nil {
                self?.beginActivity(
                    title: "Deleting from phone",
                    detail: total == 1 ? item.name : "\(index + 1) of \(total) - \(item.name)",
                    progress: total == 1 ? nil : Double(index) / Double(total)
                )
                let outcome = await Task.detached {
                    let outcome = PhoneFileBrowserService.delete(
                        serial: serial, remotePath: item.remotePath, isDirectory: item.isDirectory
                    )
                    if outcome.succeeded {
                        PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: item.remotePath)
                    }
                    return outcome
                }.value
                if !outcome.succeeded {
                    failure = "Couldn't delete \(item.name): \(outcome.message)"
                }
            }
            guard let self else { return }
            self.finishActivity()
            if let failure {
                self.errorMessage = failure
            }
            self.refresh()
        }
    }

    func rename(_ entry: PhoneFileEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let serial = serialOrExplain, !isBusy,
              !trimmed.isEmpty, trimmed != entry.name
        else { return }
        let remotePath = PhoneFileBrowserService.joined(path, entry.name)
        beginActivity(title: "Renaming on phone", detail: entry.name)
        Task.detached { [weak self] in
            let outcome = PhoneFileBrowserService.rename(
                serial: serial, remotePath: remotePath, to: trimmed
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishActivity()
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
        beginActivity(title: "Creating folder", detail: trimmed)
        Task.detached { [weak self] in
            let outcome = PhoneFileBrowserService.makeDirectory(
                serial: serial, parentPath: parentPath, name: trimmed
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishActivity()
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
    /// Set on the hosting window by AppDelegate; the key monitor matches on
    /// this instead of the (display-facing, changeable) window title.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("phone-files-window")

    @ObservedObject var model: FileBrowserModel

    @State private var isDropTargeted = false
    @State private var entriesToDelete: [PhoneFileEntry]?
    @State private var entryToRename: PhoneFileEntry?
    @State private var renameText = ""
    @State private var isNamingFolder = false
    @State private var newFolderText = ""
    @State private var selectedEntryIDs: Set<PhoneFileEntry.ID> = []
    @State private var selectionAnchorID: PhoneFileEntry.ID?
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = model.errorMessage {
                errorBanner(message)
            }
            columnHeaders
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .background {
            FileBrowserDropCaptureView(
                isTargeted: $isDropTargeted,
                onDrop: model.pushFiles
            )
        }
        .onAppear {
            model.refresh()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: model.path) { _ in
            clearSelection()
        }
        .onChange(of: model.entries.map(\.id)) { ids in
            selectedEntryIDs = selectedEntryIDs.intersection(ids)
            if let selectionAnchorID, !ids.contains(selectionAnchorID) {
                self.selectionAnchorID = selectedEntryIDs.first
            }
        }
        .onChange(of: selectedEntryIDs) { ids in
            if ids.isEmpty {
                selectionAnchorID = nil
            } else if selectionAnchorID == nil || !ids.contains(selectionAnchorID!) {
                selectionAnchorID = ids.first
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { entriesToDelete != nil },
                set: { if !$0 { entriesToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let entries = entriesToDelete { model.delete(entries) }
                entriesToDelete = nil
            }
            Button("Cancel", role: .cancel) { entriesToDelete = nil }
        } message: {
            Text(
                (entriesToDelete?.count ?? 0) > 1
                    ? "This removes them from the phone. You can't undo this."
                    : "This removes it from the phone. You can't undo this."
            )
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

            Picker("", selection: $model.viewMode) {
                Image(systemName: "list.bullet").tag(FileBrowserModel.ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(FileBrowserModel.ViewMode.gallery)
            }
            .pickerStyle(.segmented)
            .frame(width: 70)
            .help("List or gallery view")

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
            } else if model.viewMode == .gallery {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(model.sortedEntries) { entry in
                            galleryCell(entry)
                        }
                    }
                    .padding(12)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.sortedEntries) { entry in
                            rowView(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            if let activity = model.activity {
                transferActivityPanel(activity)
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

    private var columnHeaders: some View {
        HStack(spacing: 8) {
            sortHeader("Name", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
            sortHeader("Size", field: .size)
                .frame(width: 90, alignment: .trailing)
            sortHeader("Modified", field: .modified)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func sortHeader(_ title: String, field: FileBrowserModel.SortField) -> some View {
        Button {
            model.toggleSort(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortField == field {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(model.sortField == field ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let summary = selectionFooterSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Drop files here to copy them to this folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var selectedEntries: [PhoneFileEntry] {
        model.sortedEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var selectionFooterSummary: String? {
        let entries = selectedEntries
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return "\(entry.name) · \(typeDescription(for: entry)) · \(sizeDescription(for: entry))"
        }

        let folderCount = entries.filter(\.isNavigable).count
        let fileCount = entries.count - folderCount
        let knownFileBytes = entries.reduce(Int64(0)) { total, entry in
            entry.isNavigable ? total : total + (entry.sizeBytes ?? 0)
        }
        let typeText: String
        switch (fileCount, folderCount) {
        case (0, let folders):
            typeText = "\(folders) \(folders == 1 ? "folder" : "folders")"
        case (let files, 0):
            typeText = "\(files) \(files == 1 ? "file" : "files")"
        default:
            typeText = "\(fileCount) \(fileCount == 1 ? "file" : "files"), \(folderCount) \(folderCount == 1 ? "folder" : "folders")"
        }
        let size = knownFileBytes > 0
            ? PhoneFileBrowserService.formattedSize(knownFileBytes)
            : "Folder size not calculated"
        return "\(entries.count) selected · \(typeText) · \(size)"
    }

    private func typeDescription(for entry: PhoneFileEntry) -> String {
        switch entry.kind {
        case .directory:
            return "Folder"
        case .symlink:
            return "Linked folder"
        case .file:
            let ext = (entry.name as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "File" : "\(ext) file"
        case .other:
            return "Item"
        }
    }

    private func sizeDescription(for entry: PhoneFileEntry) -> String {
        entry.isNavigable
            ? "Folder size not calculated"
            : PhoneFileBrowserService.formattedSize(entry.sizeBytes)
    }

    private func transferActivityPanel(_ activity: FileTransferActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(activity.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text(activity.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress = activity.progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .frame(width: 320)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
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

    @ViewBuilder
    private func rowView(_ entry: PhoneFileEntry) -> some View {
        interactive(
            entry: entry,
            base: FileBrowserRow(entry: entry, isSelected: selectedEntryIDs.contains(entry.id))
        )
    }

    @ViewBuilder
    private func galleryCell(_ entry: PhoneFileEntry) -> some View {
        interactive(
            entry: entry,
            base: FileBrowserGalleryCell(
                entry: entry,
                model: model,
                isSelected: selectedEntryIDs.contains(entry.id)
            )
        )
    }

    /// Shared gestures for list rows and gallery cells: double-click opens,
    /// rows drag as phone entries, folder targets accept drops.
    @ViewBuilder
    private func interactive(entry: PhoneFileEntry, base: some View) -> some View {
        let decorated = base
            .contentShape(Rectangle())
            .modifier(FileBrowserClickModifier { event in
                handleClick(event, entry: entry)
            })
            .onDrag { model.dragItemProvider(for: entry) }
            .contextMenu {
                contextMenuItems(for: entry)
            }
        if entry.isNavigable {
            decorated.modifier(FolderDropTargetModifier(entry: entry, onDrop: handleRowDrop))
        } else {
            decorated
        }
    }

    /// Rows the context menu on `entry` should act on: the whole selection
    /// when the row is part of a multi-selection (like Finder), otherwise just
    /// the clicked row.
    private func contextMenuTargets(for entry: PhoneFileEntry) -> [PhoneFileEntry] {
        if selectedEntryIDs.count > 1, selectedEntryIDs.contains(entry.id) {
            return selectedEntries
        }
        return [entry]
    }

    @ViewBuilder
    private func contextMenuItems(for entry: PhoneFileEntry) -> some View {
        let targets = contextMenuTargets(for: entry)
        if targets.count > 1 {
            Button("Save \(targets.count) Items to Mac") { model.download(targets) }
            Divider()
            Button(role: .destructive) {
                entriesToDelete = targets
            } label: {
                Text(redMenuTitle("Delete \(targets.count) Items…"))
            }
        } else {
            Button("Preview") { model.preview(entry) }
            Button("Open") { model.open(entry) }
            Button("Save to Mac") { model.download(entry) }
            Button("Rename…") {
                renameText = entry.name
                entryToRename = entry
            }
            Divider()
            Button(role: .destructive) {
                entriesToDelete = [entry]
            } label: {
                // Plain foregroundColor is stripped inside menus; the
                // attributed color survives, so Delete reads red even
                // where the destructive role isn't tinted.
                Text(redMenuTitle("Delete…"))
            }
        }
    }

    private var deleteAlertTitle: String {
        guard let entries = entriesToDelete else { return "" }
        if entries.count == 1, let entry = entries.first {
            return "Delete \"\(entry.name)\"?"
        }
        return "Delete \(entries.count) items?"
    }

    private func handleClick(_ event: FileBrowserClickEvent, entry: PhoneFileEntry) {
        let flags = event.modifiers.intersection(.deviceIndependentFlagsMask)
        if event.clickCount >= 2 {
            selectedEntryIDs = [entry.id]
            selectionAnchorID = entry.id
            model.open(entry)
            return
        }
        select(entry, modifiers: flags)
    }

    private func select(_ entry: PhoneFileEntry, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift), let anchorID = selectionAnchorID {
            selectRange(from: anchorID, to: entry.id)
        } else if flags.contains(.command) {
            if selectedEntryIDs.contains(entry.id) {
                selectedEntryIDs.remove(entry.id)
            } else {
                selectedEntryIDs.insert(entry.id)
                selectionAnchorID = entry.id
            }
            if selectedEntryIDs.isEmpty {
                selectionAnchorID = nil
            }
        } else {
            selectedEntryIDs = [entry.id]
            selectionAnchorID = entry.id
        }
    }

    private func selectRange(from anchorID: PhoneFileEntry.ID, to targetID: PhoneFileEntry.ID) {
        let ids = model.sortedEntries.map(\.id)
        guard let anchorIndex = ids.firstIndex(of: anchorID),
              let targetIndex = ids.firstIndex(of: targetID)
        else {
            selectedEntryIDs = [targetID]
            selectionAnchorID = targetID
            return
        }
        let range = anchorIndex <= targetIndex
            ? anchorIndex...targetIndex
            : targetIndex...anchorIndex
        selectedEntryIDs = Set(ids[range])
    }

    private func clearSelection() {
        selectedEntryIDs.removeAll()
        selectionAnchorID = nil
    }

    /// Drop onto a folder row: internal drags move (option copies); external
    /// files copy straight into that folder.
    private func handleRowDrop(_ providers: [NSItemProvider], folder: PhoneFileEntry) -> Bool {
        let copy = NSEvent.modifierFlags.contains(.option)
        if let internalProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.phoneRelayEntry.identifier)
        }) {
            _ = internalProvider.loadDataRepresentation(
                forTypeIdentifier: UTType.phoneRelayEntry.identifier
            ) { [model] data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(PhoneEntryTransfer.self, from: data)
                else { return }
                DispatchQueue.main.async { [weak model] in
                    model?.relocate(transfer, into: folder, copy: copy)
                }
            }
            return true
        }

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
            model?.pushFiles(collector.urls, intoSubfolder: folder)
        }
        return true
    }

    private func previewSelectedEntry() {
        guard selectedEntryIDs.count == 1,
              let selectedEntryID = selectedEntryIDs.first,
              let entry = model.sortedEntries.first(where: { $0.id == selectedEntryID })
        else { return }
        model.preview(entry)
    }

    private func openSelectedEntry() {
        guard selectedEntryIDs.count == 1,
              let selectedEntryID = selectedEntryIDs.first,
              let entry = model.sortedEntries.first(where: { $0.id == selectedEntryID })
        else { return }
        model.open(entry)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.identifier == Self.windowIdentifier,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !isTextEditingFirstResponder
            else { return event }
            switch event.keyCode {
            case 36:
                openSelectedEntry()
                return nil
            case 49:
                previewSelectedEntry()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private var isTextEditingFirstResponder: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
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

private final class FileQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL
    }
}

private struct FileBrowserDropCaptureView: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, onDrop: onDrop)
    }

    func makeNSView(context: Context) -> DropCaptureNSView {
        let view = DropCaptureNSView()
        view.coordinator = context.coordinator
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: DropCaptureNSView, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.onDrop = onDrop
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var isTargeted: Binding<Bool>
        var onDrop: ([URL]) -> Void

        init(isTargeted: Binding<Bool>, onDrop: @escaping ([URL]) -> Void) {
            self.isTargeted = isTargeted
            self.onDrop = onDrop
        }
    }

    final class DropCaptureNSView: NSView {
        weak var coordinator: Coordinator?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard droppedFileURLs(from: sender).isEmpty == false else { return [] }
            coordinator?.isTargeted.wrappedValue = true
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            droppedFileURLs(from: sender).isEmpty ? [] : .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            coordinator?.isTargeted.wrappedValue = false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            coordinator?.isTargeted.wrappedValue = false
            let urls = droppedFileURLs(from: sender)
            guard !urls.isEmpty else { return false }
            coordinator?.onDrop(urls)
            return true
        }

        private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            return sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [URL] ?? []
        }
    }
}

private struct FolderDropTargetModifier: ViewModifier {
    let entry: PhoneFileEntry
    let onDrop: ([NSItemProvider], PhoneFileEntry) -> Bool

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                }
            }
            .onDrop(of: [.phoneRelayEntry, .fileURL], isTargeted: $isTargeted) { providers in
                onDrop(providers, entry)
            }
    }
}

private struct FileBrowserClickEvent {
    var clickCount: Int
    var modifiers: NSEvent.ModifierFlags
    var timestamp: TimeInterval
}

private struct FileBrowserClickModifier: ViewModifier {
    let onClick: (FileBrowserClickEvent) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            FileBrowserClickCaptureView(onClick: onClick)
        }
    }
}

private struct FileBrowserClickCaptureView: NSViewRepresentable {
    let onClick: (FileBrowserClickEvent) -> Void

    func makeNSView(context: Context) -> ClickCaptureNSView {
        let view = ClickCaptureNSView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickCaptureNSView, context: Context) {
        nsView.onClick = onClick
    }

    final class ClickCaptureNSView: NSView {
        var onClick: ((FileBrowserClickEvent) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(
                FileBrowserClickEvent(
                    clickCount: event.clickCount,
                    modifiers: event.modifierFlags,
                    timestamp: event.timestamp
                )
            )
        }
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

private struct FileBrowserGalleryCell: View {
    let entry: PhoneFileEntry
    let model: FileBrowserModel
    let isSelected: Bool

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tileFill)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: entry.isNavigable ? "folder.fill" : fallbackIcon)
                        .font(.system(size: 34))
                        .foregroundStyle(
                            entry.isNavigable ? Color.accentColor : Color.secondary
                        )
                }
            }
            .frame(width: 96, height: 96)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tileStroke, lineWidth: isSelected ? 1.5 : 1)
            }
            Text(entry.name)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 110)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(cellFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(cellStroke, lineWidth: isSelected ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .onHover { isHovering = $0 }
        .task(id: entry.id) {
            guard thumbnail == nil,
                  PhoneThumbnailStore.isThumbnailable(entry),
                  let context = model.thumbnailContext
            else { return }
            let loaded = await Task.detached(priority: .utility) {
                model.loadThumbnail(
                    directory: context.directory, entry: entry, serial: context.serial
                )
            }.value
            if !Task.isCancelled { thumbnail = loaded }
        }
    }

    private var cellFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.20)
        }
        if isHovering {
            return Color.accentColor.opacity(0.10)
        }
        return .clear
    }

    private var cellStroke: Color {
        if isSelected {
            return Color.accentColor.opacity(0.62)
        }
        if isHovering {
            return Color.accentColor.opacity(0.28)
        }
        return .clear
    }

    private var tileFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.secondary.opacity(0.14)
        }
        return Color.secondary.opacity(0.08)
    }

    private var tileStroke: Color {
        if isSelected {
            return Color.accentColor.opacity(0.78)
        }
        if isHovering {
            return Color.secondary.opacity(0.24)
        }
        return .clear
    }

    private var fallbackIcon: String {
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

private struct FileBrowserRow: View {
    let entry: PhoneFileEntry
    let isSelected: Bool
    @State private var isHovering = false

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
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(rowFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(rowStroke, lineWidth: isSelected ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.20)
        }
        if isHovering {
            return Color.accentColor.opacity(0.12)
        }
        return .clear
    }

    private var rowStroke: Color {
        if isSelected {
            return Color.accentColor.opacity(0.62)
        }
        if isHovering {
            return Color.accentColor.opacity(0.28)
        }
        return .clear
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
