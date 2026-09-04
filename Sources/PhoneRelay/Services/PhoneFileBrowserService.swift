import Foundation

/// One row in a phone directory listing.
struct PhoneFileEntry: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
        /// Symlinks on /sdcard are almost always directories (e.g. /sdcard
        /// itself); navigation treats them as folders and surfaces the shell
        /// error if the target turns out to be a file.
        case symlink
        case other
    }

    var name: String
    var kind: Kind
    var sizeBytes: Int64?
    /// Raw "YYYY-MM-DD HH:MM" from the phone's clock. Kept as text — the
    /// phone's timezone is unknown, so converting to Date would lie.
    var modifiedText: String
    var symlinkTarget: String?

    var id: String { name }
    var isNavigable: Bool { kind == .directory || kind == .symlink }
}

/// Free/total bytes for the volume backing a phone path.
struct PhoneStorageInfo: Equatable, Sendable {
    var totalBytes: Int64
    var freeBytes: Int64
}

/// Blocking adb file operations for the phone file browser. All methods hit
/// the adb CLI and must be called from a detached Task, never the main actor
/// (see the NotificationForwarder freeze). `shell`/`push`/`pull` are not in
/// `ADBController.serializedCommands`, so nothing here can stall a
/// connect/handoff flow.
enum PhoneFileBrowserService {

    /// Browsing is confined to shared storage; the shell user can't read
    /// /data, and showing permission errors for it is just noise.
    nonisolated static let allowedRootPrefixes = ["/sdcard", "/storage"]
    nonisolated static let defaultRoot = "/sdcard"

    nonisolated static func isPathAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." })
        else { return false }
        let normalizedPath = "/" + components.joined(separator: "/")
        return allowedRootPrefixes.contains { prefix in
            normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/")
        }
    }

    /// A single path component the user typed (new folder / rename). `.` and
    /// `..` would resolve to a different directory than the one shown, so a
    /// rename to ".." could move the entry out of the allowed roots.
    nonisolated static func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    // MARK: - Shell quoting

    /// Wraps a remote path for the phone-side shell. adb passes `shell`
    /// arguments through a remote sh, so every path gets exactly one layer
    /// of single-quote escaping ('\'' for embedded quotes).
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins a directory and a child name without normalizing anything else;
    /// names come verbatim from `ls` output.
    nonisolated static func joined(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Parent directory, clamped at the allowed roots so Back can't escape
    /// shared storage.
    nonisolated static func parent(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return nil }
        let parent = String(path[path.startIndex..<slash])
        return isPathAllowed(parent) ? parent : nil
    }

    /// Resolve symlinks on the phone before any operation that may follow
    /// them. A path may look like `/sdcard/...` while its final target lives
    /// elsewhere, so both the lexical path and the resolved target must remain
    /// inside shared storage. Failure is closed, including on devices without
    /// a usable `readlink -f` implementation.
    nonisolated static func resolvedAllowedPath(
        serial: String,
        path: String,
        timeout: TimeInterval = 5
    ) -> String? {
        guard isPathAllowed(path) else { return nil }
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "readlink", "-f", shellQuoted(path)],
            timeout: timeout
        )
        guard result.succeeded else { return nil }
        let lines = result.output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, isPathAllowed(lines[0]) else { return nil }
        return lines[0]
    }

    // MARK: - Directory listing

    /// Matches one toybox `ls -l -a` row: perms, links, owner, group, size,
    /// date, time, then the raw name (which may contain spaces, quotes, or
    /// "name -> target" for symlinks). SELinux marks (`.`/`+`) after the
    /// permission bits and second-precision timestamps both occur in the
    /// wild, so both are optional.
    nonisolated private static let listingLinePattern =
        #"^([bcdlps-])[rwxsStT-]{9}[.+]?\s+\d+\s+\S+\s+\S+\s+(\d+|\?)(?:,\s*\d+)?\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:\s+[+-]\d{4})?)\s(.*)$"#

    struct ListingParseResult: Equatable, Sendable {
        var entries: [PhoneFileEntry]
        var skippedLines: Int
    }

    /// Parses merged `adb shell ls -l -a` output. Unrecognized lines are
    /// counted, not fatal — one unstat-able file shouldn't blank the folder.
    nonisolated static func parseListing(_ output: String) -> ListingParseResult {
        let regex = try? NSRegularExpression(pattern: listingLinePattern)
        var entries: [PhoneFileEntry] = []
        var skipped = 0

        // Older adbd transports emit CRLF; "\r\n" is a single Character in
        // Swift, so splitting on "\n" alone would never split those lines.
        for rawLine in output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine).replacingOccurrences(of: "\r", with: "")
            if line.isEmpty || line.hasPrefix("total ") { continue }
            guard let regex,
                  let match = regex.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                  ),
                  let typeRange = Range(match.range(at: 1), in: line),
                  let sizeRange = Range(match.range(at: 2), in: line),
                  let dateRange = Range(match.range(at: 3), in: line),
                  let timeRange = Range(match.range(at: 4), in: line),
                  let nameRange = Range(match.range(at: 5), in: line)
            else {
                skipped += 1
                continue
            }

            let typeChar = line[typeRange]
            var name = String(line[nameRange])
            var symlinkTarget: String?
            if typeChar == "l", let arrow = name.range(of: " -> ") {
                symlinkTarget = String(name[arrow.upperBound...])
                name = String(name[name.startIndex..<arrow.lowerBound])
            }
            if name.isEmpty || name == "." || name == ".." {
                continue
            }

            let kind: PhoneFileEntry.Kind
            switch typeChar {
            case "d": kind = .directory
            case "-": kind = .file
            case "l": kind = .symlink
            default: kind = .other
            }

            // Timestamps with seconds keep only HH:MM for display.
            let time = String(line[timeRange].prefix(5))
            entries.append(PhoneFileEntry(
                name: name,
                kind: kind,
                sizeBytes: Int64(line[sizeRange]),
                modifiedText: "\(line[dateRange]) \(time)",
                symlinkTarget: symlinkTarget
            ))
        }

        entries.sort {
            if $0.isNavigable != $1.isNavigable { return $0.isNavigable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return ListingParseResult(entries: entries, skippedLines: skipped)
    }

    enum ServiceError: Error, Equatable {
        case pathNotAllowed
        case operationFailed(String)

        var message: String {
            switch self {
            case .pathNotAllowed: return "That folder is outside shared storage."
            case .operationFailed(let detail): return detail
            }
        }
    }

    /// Lists a phone directory. The trailing slash forces the shell to
    /// dereference symlinked directories (like /sdcard itself) instead of
    /// stat-ing the link.
    nonisolated static func listDirectory(
        serial: String,
        path: String
    ) -> Result<ListingParseResult, ServiceError> {
        guard let resolvedPath = resolvedAllowedPath(serial: serial, path: path) else {
            return .failure(.pathNotAllowed)
        }
        let target = resolvedPath.hasSuffix("/") ? resolvedPath : resolvedPath + "/"
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "ls", "-l", "-a", shellQuoted(target)],
            timeout: 20
        )
        guard result.succeeded else {
            return .failure(.operationFailed(oneLine(result.output)))
        }
        // Permission-denied noise for individual children arrives on the same
        // merged stream; parseListing already skips those lines.
        return .success(parseListing(result.output))
    }

    /// Stats a single path via `ls -l -d` (one listing row, same parser).
    /// Returns nil when the path doesn't exist or isn't readable.
    nonisolated static func statPath(serial: String, path: String) -> PhoneFileEntry? {
        guard let resolvedPath = resolvedAllowedPath(serial: serial, path: path) else { return nil }
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "ls", "-l", "-d", shellQuoted(resolvedPath)],
            timeout: 10
        )
        guard result.succeeded else { return nil }
        guard var entry = parseListing(result.output).entries.first else { return nil }
        // `ls -d` echoes the full path as the name; callers want the leaf.
        entry.name = (entry.name as NSString).lastPathComponent
        return entry
    }

    // MARK: - Storage info

    /// Parses `df -k <path>` output (1K blocks). Returns nil rather than
    /// guessing when the format is unfamiliar — the storage bar just hides.
    nonisolated static func parseStorageInfo(_ output: String) -> PhoneStorageInfo? {
        for rawLine in output.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 4,
                  let totalKB = Int64(columns[1]),
                  let availableKB = Int64(columns[3]),
                  totalKB > 0
            else { continue }
            return PhoneStorageInfo(
                totalBytes: totalKB * 1024,
                freeBytes: availableKB * 1024
            )
        }
        return nil
    }

    nonisolated static func storageInfo(serial: String, path: String) -> PhoneStorageInfo? {
        guard let resolvedPath = resolvedAllowedPath(serial: serial, path: path) else { return nil }
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "df", "-k", shellQuoted(resolvedPath)],
            timeout: 10
        )
        guard result.succeeded else { return nil }
        return parseStorageInfo(result.output)
    }

    // MARK: - Transfers and mutations

    struct OperationOutcome: Equatable, Sendable {
        var succeeded: Bool
        var message: String
    }

    /// `adb push` — paths are passed natively to adb (no remote shell), so
    /// they are NOT quoted.
    nonisolated static func push(
        serial: String,
        localPath: String,
        remoteDirectory: String
    ) -> OperationOutcome {
        guard let resolvedDirectory = resolvedAllowedPath(serial: serial, path: remoteDirectory) else {
            return OperationOutcome(succeeded: false, message: "Destination not allowed")
        }
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "push", localPath, resolvedDirectory + "/"],
            timeout: 600
        )
        return OperationOutcome(succeeded: result.succeeded, message: oneLine(result.output))
    }

    /// `adb pull` into a local directory, returning the local destination on
    /// success. Collision-proofs the filename the way Finder does.
    nonisolated static func pull(
        serial: String,
        remotePath: String,
        localDirectory: URL
    ) -> Result<URL, ServiceError> {
        guard let resolvedPath = resolvedAllowedPath(serial: serial, path: remotePath) else {
            return .failure(.pathNotAllowed)
        }
        let name = (remotePath as NSString).lastPathComponent
        let destination = availableDestination(for: name, in: localDirectory)
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "pull", resolvedPath, destination.path],
            timeout: 600
        )
        guard result.succeeded else { return .failure(.operationFailed(oneLine(result.output))) }
        return .success(destination)
    }

    nonisolated static func availableDestination(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    nonisolated static func delete(
        serial: String,
        remotePath: String,
        isDirectory: Bool
    ) -> OperationOutcome {
        guard resolvedAllowedPath(serial: serial, path: remotePath) != nil else {
            return OperationOutcome(succeeded: false, message: "Path not allowed")
        }
        let flags = isDirectory ? "-rf" : "-f"
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "rm", flags, shellQuoted(remotePath)],
            timeout: 120
        )
        return OperationOutcome(succeeded: result.succeeded, message: oneLine(result.output))
    }

    nonisolated static func makeDirectory(
        serial: String,
        parentPath: String,
        name: String
    ) -> OperationOutcome {
        guard isValidEntryName(name) else {
            return OperationOutcome(succeeded: false, message: "Invalid folder name")
        }
        guard let resolvedParent = resolvedAllowedPath(serial: serial, path: parentPath) else {
            return OperationOutcome(succeeded: false, message: "Path not allowed")
        }
        let path = joined(resolvedParent, name)
        guard isPathAllowed(path) else {
            return OperationOutcome(succeeded: false, message: "Path not allowed")
        }
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "mkdir", shellQuoted(path)],
            timeout: 15
        )
        return OperationOutcome(succeeded: result.succeeded, message: oneLine(result.output))
    }

    nonisolated static func rename(
        serial: String,
        remotePath: String,
        to newName: String
    ) -> OperationOutcome {
        guard isValidEntryName(newName),
              resolvedAllowedPath(serial: serial, path: remotePath) != nil,
              let directory = parent(of: remotePath),
              resolvedAllowedPath(serial: serial, path: directory) != nil
        else {
            return OperationOutcome(succeeded: false, message: "Invalid name")
        }
        let destination = joined(directory, newName)
        let result = Tooling.runResult(
            "adb",
            arguments: [
                "-s", serial, "shell", "mv",
                shellQuoted(remotePath), shellQuoted(destination)
            ],
            timeout: 30
        )
        return OperationOutcome(succeeded: result.succeeded, message: oneLine(result.output))
    }

    /// Moves (or copies) a phone file/folder into another phone directory,
    /// keeping its name. Backs the in-window drag-and-drop.
    nonisolated static func relocate(
        serial: String,
        remotePath: String,
        intoDirectory directory: String,
        copy: Bool
    ) -> OperationOutcome {
        let name = (remotePath as NSString).lastPathComponent
        let lexicalDestination = joined(directory, name)
        guard isPathAllowed(remotePath), isPathAllowed(lexicalDestination) else {
            return OperationOutcome(succeeded: false, message: "Path not allowed")
        }
        guard lexicalDestination != remotePath, directory != remotePath else {
            return OperationOutcome(succeeded: true, message: "")
        }
        guard resolvedAllowedPath(serial: serial, path: remotePath) != nil,
              let resolvedDirectory = resolvedAllowedPath(serial: serial, path: directory)
        else {
            return OperationOutcome(succeeded: false, message: "Path not allowed")
        }
        let destination = joined(resolvedDirectory, name)
        guard isPathAllowed(destination) else {
            return OperationOutcome(succeeded: false, message: "Path not allowed")
        }
        let command = copy ? ["cp", "-r"] : ["mv"]
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell"] + command + [
                shellQuoted(remotePath), shellQuoted(destination)
            ],
            timeout: 300
        )
        return OperationOutcome(succeeded: result.succeeded, message: oneLine(result.output))
    }

    /// Best-effort media rescan so pushed/deleted files show up in the
    /// phone's Gallery. Tries the Android 11+ volume scan first, then the
    /// legacy broadcast; both failing is harmless (files still transferred).
    nonisolated static func requestMediaScan(serial: String, remotePath: String) {
        guard let resolvedPath = resolvedAllowedPath(serial: serial, path: remotePath) else { return }
        let volumeScan = Tooling.runResult(
            "adb",
            arguments: [
                "-s", serial, "shell", "content", "call",
                "--uri", "content://media", "--method", "scan_volume",
                "--arg", "external_primary"
            ],
            timeout: 15
        )
        if volumeScan.succeeded && !volumeScan.output.contains("Error") { return }
        _ = Tooling.runResult(
            "adb",
            arguments: [
                "-s", serial, "shell", "am", "broadcast",
                "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                "-d", shellQuoted("file://" + resolvedPath)
            ],
            timeout: 10
        )
    }

    // MARK: - Local temp pulls

    /// Root under the user temp dir where opens/previews/drags pull phone
    /// files. Each pull gets a fresh UUID subdirectory.
    nonisolated static let temporaryPullRootName = "PhoneRelay Files"

    nonisolated static func makeTemporaryPullDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryPullRootName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Deletes pulled copies left behind by earlier sessions — every open,
    /// preview, and drag pulls the full file here and nothing removed them, so
    /// browsing videos could park gigabytes until macOS purged the temp dir.
    /// Only entries older than `maxAge` go, so a file the user still has open
    /// in another app from a recent session is left alone. Blocking; call off
    /// the main thread, once per launch.
    nonisolated static func cleanUpStaleTemporaryPulls(
        maxAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryPullRootName, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for child in children {
            guard let modified = (try? child.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate,
                now.timeIntervalSince(modified) > maxAge
            else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    // MARK: - Formatting

    nonisolated static func formattedSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated static func oneLine(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
    }
}
