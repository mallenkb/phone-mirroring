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
    /// Phone name and how it's connected ("Wi-Fi", "USB"), for the sidebar.
    private let deviceSummaryProvider: () -> (name: String, connection: String?)?
    private var loadGeneration = 0
    private var quickLookController: FileQuickLookController?

    /// Finder-style history: Back returns to the previous folder, not
    /// necessarily the parent (sidebar jumps skip levels).
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    /// Filters the current folder by name; cleared on navigation.
    @Published var searchText = ""
    @Published var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: FileBrowserModel.showHiddenDefaultsKey) {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenDefaultsKey) }
    }
    static let showHiddenDefaultsKey = "PhoneFiles.showHiddenFiles"

    init(
        serialProvider: @escaping () -> String?,
        deviceSummaryProvider: @escaping () -> (name: String, connection: String?)? = { nil }
    ) {
        self.serialProvider = serialProvider
        self.deviceSummaryProvider = deviceSummaryProvider
    }

    var deviceSummary: (name: String, connection: String?)? { deviceSummaryProvider() }
    var isPhoneConnected: Bool { !(serialProvider() ?? "").isEmpty }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { PhoneFileBrowserService.parent(of: path) != nil }

    /// Entries after the hidden-file and search filters, in sort order.
    var visibleEntries: [PhoneFileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sortedEntries.filter { entry in
            (showHiddenFiles || !FileBrowserPresentation.isHidden(entry))
                && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query))
        }
    }

    var hiddenEntryCount: Int {
        showHiddenFiles ? 0 : entries.filter(FileBrowserPresentation.isHidden).count
    }

    /// Moves to `newPath`, recording history unless Back/Forward did it.
    func navigate(to newPath: String, recordHistory: Bool = true) {
        guard !isBusy, newPath != path, PhoneFileBrowserService.isPathAllowed(newPath) else { return }
        if recordHistory {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        searchText = ""
        entries = []
        refresh()
    }

    func goForward() {
        guard !isBusy, let next = forwardStack.popLast() else { return }
        backStack.append(path)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard let parent = PhoneFileBrowserService.parent(of: path) else { return }
        navigate(to: parent)
    }

    /// Opens a sidebar place, trying its paths in order until one exists.
    func open(_ place: FileBrowserPlace) {
        guard !isBusy, let serial = serialOrExplain else { return }
        guard place.paths.count > 1 else {
            if let only = place.paths.first { navigate(to: only) }
            return
        }
        let candidates = place.paths
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = candidates.first { candidate in
                PhoneFileBrowserService.statPath(serial: serial, path: candidate)?.isNavigable == true
            } ?? candidates[0]
            await MainActor.run { [weak self] in self?.navigate(to: found) }
        }
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
    nonisolated func loadThumbnailData(directory: String, entry: PhoneFileEntry, serial: String) -> Data? {
        PhoneThumbnailStore.shared.thumbnailPNGData(
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
        navigate(to: PhoneFileBrowserService.joined(path, entry.name))
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
        guard !isBusy else { return }
        guard let previous = backStack.popLast() else {
            goUp()
            return
        }
        forwardStack.append(path)
        navigate(to: previous, recordHistory: false)
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
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if let message = model.errorMessage, model.isPhoneConnected {
                    errorBanner(message)
                }
                if !model.isPhoneConnected {
                    noPhoneState
                } else {
                    if model.viewMode == .list {
                        columnHeaders
                        Divider()
                    }
                    content
                    Divider()
                    footer
                }
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .ignoresSafeArea(.container, edges: .top)
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            deviceCard
                .padding(.horizontal, 10)
                .padding(.top, 44)  // clears the traffic lights
                .padding(.bottom, 14)

            Text("Locations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)

            VStack(spacing: 1) {
                ForEach(FileBrowserPlace.all) { place in
                    sidebarRow(place)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            if let storage = model.storage, model.isPhoneConnected {
                storageCard(storage)
                    .padding(10)
            }
        }
        .frame(width: 216)
        .background(Color.primary.opacity(0.035))
    }

    private var deviceCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "smartphone")
                .font(.system(size: 18))
                .foregroundStyle(model.isPhoneConnected ? Color.primary : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceSummary?.name ?? "Android phone")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isPhoneConnected ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(connectionText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var connectionText: String {
        guard model.isPhoneConnected else { return "Not connected" }
        guard let connection = model.deviceSummary?.connection, !connection.isEmpty else { return "Connected" }
        let lower = connection.lowercased()
        if lower.contains("usb") { return "Connected by USB" }
        if lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("wireless") { return "Connected over Wi-Fi" }
        return "Connected"
    }

    private func sidebarRow(_ place: FileBrowserPlace) -> some View {
        let isCurrent = FileBrowserPlace.current(for: model.path)?.id == place.id
        return Button {
            model.open(place)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: place.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(place.title)
                    .font(.system(size: 13, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isPhoneConnected || model.isBusy)
        .opacity(model.isPhoneConnected ? 1 : 0.45)
    }

    private func storageCard(_ storage: PhoneStorageInfo) -> some View {
        let used = FileBrowserPresentation.usedFraction(storage)
        let level = FileBrowserPresentation.storageLevel(storage)
        let tint: Color = level == .almostFull ? .red : (level == .low ? .orange : .accentColor)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int((used * 100).rounded()))% full")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint).frame(width: max(4, proxy.size.width * used))
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Storage \(Int((used * 100).rounded())) percent full")
            Text(FileBrowserPresentation.storageSummary(storage))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if level == .almostFull {
                Label("Almost full", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07)))
    }

    // MARK: - Toolbar

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 22)
            }
            .disabled(!(model.canGoBack || model.canGoUp) || model.isBusy || !model.isPhoneConnected)
            .help("Back (⌘[)")

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 22)
            }
            .disabled(!model.canGoForward || model.isBusy || !model.isPhoneConnected)
            .help("Forward (⌘])")

            pathBar
                .padding(.leading, 2)

            Spacer(minLength: 8)

            if model.isPhoneConnected {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search \(FileBrowserPresentation.title(for: model.path))", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isSearchFocused)
                        .onExitCommand { model.searchText = ""; isSearchFocused = false }
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 210, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .help("Search this folder (⌘F)")

                Picker("", selection: $model.viewMode) {
                    Image(systemName: "list.bullet").tag(FileBrowserModel.ViewMode.list)
                    Image(systemName: "square.grid.2x2").tag(FileBrowserModel.ViewMode.gallery)
                }
                .pickerStyle(.segmented)
                .frame(width: 72)
                .help("List or gallery view")

                Button {
                    newFolderText = ""
                    isNamingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 26, height: 22)
                }
                .disabled(model.isBusy)
                .help("New folder (⇧⌘N)")

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 22)
                }
                .disabled(model.isBusy)
                .help("Refresh (⌘R)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    /// Clickable path: every ancestor jumps straight there.
    private var pathBar: some View {
        let segments = model.isPhoneConnected
            ? FileBrowserPresentation.pathSegments(for: model.path)
            : [FileBrowserPresentation.PathSegment(title: "Phone Files", path: "")]
        return HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if index == segments.count - 1 {
                    Text(segment.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.isPhoneConnected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                } else {
                    Button(segment.title) { model.navigate(to: segment.path) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if model.isLoading && model.entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleEntries.isEmpty {
                emptyFolderState
            } else if model.viewMode == .gallery {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 116), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(model.visibleEntries) { entry in
                            galleryCell(entry)
                        }
                    }
                    .padding(12)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                            rowView(entry, isStriped: index % 2 == 1)
                        }
                    }
                    .padding(.horizontal, 8)
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
                .padding(.leading, 30)
            Text("Kind")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: FileBrowserRow.kindWidth, alignment: .leading)
            sortHeader("Size", field: .size)
                .frame(width: FileBrowserRow.sizeWidth, alignment: .trailing)
            sortHeader("Date Modified", field: .modified)
                .frame(width: FileBrowserRow.dateWidth, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 26)
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.sortField == field ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: 11, weight: selectedEntryIDs.isEmpty ? .regular : .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if !selectedEntries.isEmpty {
                Button("Delete…") { entriesToDelete = selectedEntries }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                Button {
                    model.download(selectedEntries)
                } label: {
                    Label("Download to Mac", systemImage: "arrow.down.to.line")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            } else {
                if model.hiddenEntryCount > 0 {
                    Button("Show \(model.hiddenEntryCount) hidden \(model.hiddenEntryCount == 1 ? "item" : "items")") {
                        model.showHiddenFiles = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .help("Show files whose names start with a dot (⇧⌘.)")
                } else if model.showHiddenFiles {
                    Button("Hide hidden items") { model.showHiddenFiles = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                Divider().frame(height: 12)
                Label("Drop files to copy here", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: selectedEntries.isEmpty ? 28 : 40)
    }

    /// "14 items · 5.2 GB available", or a summary of the selection.
    private var statusText: String {
        if let summary = selectionFooterSummary { return summary }
        var parts: [String] = []
        let visible = model.visibleEntries.count
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(FileBrowserPresentation.itemCount(visible))
        } else {
            parts.append("\(visible) of \(FileBrowserPresentation.itemCount(model.entries.count)) match")
        }
        if let storage = model.storage {
            parts.append("\(FileBrowserPresentation.gigabytes(storage.freeBytes)) available")
        }
        return parts.joined(separator: " · ")
    }

    private var emptyFolderState: some View {
        let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "folder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            if model.errorMessage == nil {
                Text(searching ? "No matches for \u{201C}\(model.searchText)\u{201D}" : "This folder is empty")
                    .font(.system(size: 14, weight: .semibold))
                Text(searching
                     ? "Only this folder is searched."
                     : (model.hiddenEntryCount > 0 ? "It only has hidden items." : "Drop files here to copy them to the phone."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noPhoneState: some View {
        VStack(spacing: 12) {
            Image(systemName: "smartphone.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 84)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
            Text("Your phone isn\u{2019}t connected")
                .font(.system(size: 18, weight: .semibold))
            Text("Connect it with a USB cable, or make sure it\u{2019}s on the same Wi-Fi as this Mac. Its files show up here as soon as it connects.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again") { model.refresh() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedEntries: [PhoneFileEntry] {
        model.visibleEntries.filter { selectedEntryIDs.contains($0.id) }
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
    private func rowView(_ entry: PhoneFileEntry, isStriped: Bool) -> some View {
        interactive(
            entry: entry,
            base: FileBrowserRow(entry: entry, isSelected: selectedEntryIDs.contains(entry.id), isStriped: isStriped)
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
        let ids = model.visibleEntries.map(\.id)
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
              let entry = model.visibleEntries.first(where: { $0.id == selectedEntryID })
        else { return }
        model.preview(entry)
    }

    private func openSelectedEntry() {
        guard selectedEntryIDs.count == 1,
              let selectedEntryID = selectedEntryIDs.first,
              let entry = model.visibleEntries.first(where: { $0.id == selectedEntryID })
        else { return }
        model.open(entry)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.identifier == Self.windowIdentifier else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // Finder shortcuts work even while the search field has focus.
            if flags == .command {
                switch event.keyCode {
                case 33: model.goBack(); return nil                       // ⌘[
                case 30: model.goForward(); return nil                    // ⌘]
                case 126: model.goUp(); return nil                        // ⌘↑
                case 125: openSelectedEntry(); return nil                 // ⌘↓
                case 3: isSearchFocused = true; return nil                // ⌘F
                case 15: model.refresh(); return nil                      // ⌘R
                case 51:                                                  // ⌘⌫
                    guard !isTextEditingFirstResponder, !selectedEntries.isEmpty else { return event }
                    entriesToDelete = selectedEntries
                    return nil
                default: break
                }
            }
            if flags == [.command, .shift] {
                switch event.keyCode {
                case 47: model.showHiddenFiles.toggle(); return nil       // ⇧⌘.
                case 45:                                                  // ⇧⌘N
                    newFolderText = ""
                    isNamingFolder = true
                    return nil
                default: break
                }
            }
            guard flags.isEmpty, !isTextEditingFirstResponder else { return event }
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
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(tileFill)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    FileBrowserEntryIcon(entry: entry, size: 40)
                        .frame(width: 104, height: 104)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(6)
                }
            }
            .frame(width: 104, height: 104)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor : (isHovering ? Color.primary.opacity(0.18) : Color.clear),
                                  lineWidth: isSelected ? 3 : 1)
            }
            Text(entry.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
            Text(FileBrowserPresentation.friendlyDate(entry.modifiedText))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 116)
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .onHover { isHovering = $0 }
        .task(id: entry.id) {
            guard thumbnail == nil,
                  PhoneThumbnailStore.isThumbnailable(entry),
                  let context = model.thumbnailContext
            else { return }
            let loadedData = await Task.detached(priority: .utility) {
                model.loadThumbnailData(
                    directory: context.directory, entry: entry, serial: context.serial
                )
            }.value
            if !Task.isCancelled, let loadedData {
                thumbnail = NSImage(data: loadedData)
            }
        }
    }

    private var tileFill: Color {
        if entry.isNavigable && thumbnail == nil {
            return isHovering ? Color.primary.opacity(0.06) : .clear
        }
        return isHovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05)
    }

}

struct FileBrowserRow: View {
    static let kindWidth: CGFloat = 110
    static let sizeWidth: CGFloat = 76
    static let dateWidth: CGFloat = 170

    let entry: PhoneFileEntry
    let isSelected: Bool
    var isStriped = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                FileBrowserEntryIcon(entry: entry, size: 18, isOnSelection: isSelected)
                Text(entry.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(FileBrowserPresentation.isHidden(entry) && !isSelected ? 0.6 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(FileBrowserPresentation.kind(for: entry))
                .frame(width: Self.kindWidth, alignment: .leading)
            Text(entry.isNavigable ? "—" : PhoneFileBrowserService.formattedSize(entry.sizeBytes))
                .frame(width: Self.sizeWidth, alignment: .trailing)
            Text(FileBrowserPresentation.friendlyDate(entry.modifiedText))
                .frame(width: Self.dateWidth, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill)
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor }
        if isHovering { return Color.primary.opacity(0.06) }
        return isStriped ? Color.primary.opacity(0.03) : .clear
    }
}

/// Folder (with a badge for well-known folders) or file-type icon.
struct FileBrowserEntryIcon: View {
    let entry: PhoneFileEntry
    var size: CGFloat = 18
    var isOnSelection = false

    var body: some View {
        if entry.isNavigable {
            ZStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: size))
                    .foregroundStyle(isOnSelection ? Color.white.opacity(0.9) : Color(red: 0.42, green: 0.68, blue: 0.96))
                if let badge = FileBrowserPresentation.folderBadgeSymbol(for: entry.name) {
                    Image(systemName: badge)
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(isOnSelection ? Color.accentColor : Color(red: 0.13, green: 0.40, blue: 0.75))
                        .offset(y: size * 0.07)
                }
            }
            .frame(width: size + 4)
        } else {
            Image(systemName: FileBrowserPresentation.fileSymbol(for: entry.name))
                .font(.system(size: size * 0.85))
                .foregroundStyle(isOnSelection ? Color.white : Color.secondary)
                .frame(width: size + 4)
        }
    }
}
