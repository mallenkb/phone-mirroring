import Foundation

/// A sidebar shortcut in Phone Files. `paths` are tried in order: phone
/// makers disagree on some folders (Samsung keeps screenshots in
/// DCIM/Screenshots, Pixels in Pictures/Screenshots).
struct FileBrowserPlace: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let paths: [String]

    static let all: [FileBrowserPlace] = [
        .init(id: "storage", title: "Internal storage", symbol: "internaldrive", paths: ["/sdcard"]),
        .init(id: "camera", title: "Camera", symbol: "camera", paths: ["/sdcard/DCIM/Camera", "/sdcard/DCIM"]),
        .init(id: "screenshots", title: "Screenshots", symbol: "viewfinder",
              paths: ["/sdcard/DCIM/Screenshots", "/sdcard/Pictures/Screenshots"]),
        .init(id: "downloads", title: "Downloads", symbol: "arrow.down.circle", paths: ["/sdcard/Download"]),
        .init(id: "pictures", title: "Pictures", symbol: "photo.on.rectangle", paths: ["/sdcard/Pictures"]),
        .init(id: "documents", title: "Documents", symbol: "doc", paths: ["/sdcard/Documents"]),
        .init(id: "music", title: "Music", symbol: "music.note", paths: ["/sdcard/Music"]),
        .init(id: "movies", title: "Movies", symbol: "film", paths: ["/sdcard/Movies"]),
    ]

    /// The place whose folder is showing, for the sidebar highlight.
    static func current(for path: String) -> FileBrowserPlace? {
        all.first { $0.paths.contains(path) }
    }
}

/// Pure formatting for the Phone Files window, kept out of the view so it
/// can be tested.
enum FileBrowserPresentation {
    // MARK: Path bar

    struct PathSegment: Equatable {
        let title: String
        let path: String
    }

    static func pathSegments(for path: String) -> [PathSegment] {
        let root = PhoneFileBrowserService.defaultRoot
        var segments: [PathSegment] = []
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if current == root {
                segments = [PathSegment(title: "Internal storage", path: current)]
            } else if current.count > root.count || !root.hasPrefix(current) {
                segments.append(PathSegment(title: String(component), path: current))
            }
        }
        return segments.isEmpty ? [PathSegment(title: "Internal storage", path: root)] : segments
    }

    static func title(for path: String) -> String {
        pathSegments(for: path).last?.title ?? "Internal storage"
    }

    // MARK: Dates

    /// "Today at 13:16", "Yesterday at 20:43", otherwise "9 Jul 2026 at 20:43".
    /// The phone reports its local wall-clock time with no zone, so the
    /// components are formatted as-is rather than converted.
    static func friendlyDate(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = text.split(separator: " ")
        guard parts.count >= 2 else { return text }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let time = parts[1].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, time.count >= 2 else { return text }
        let clock = String(format: "%02d:%02d", time[0], time[1])
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        if day[0] == today.year, day[1] == today.month, day[2] == today.day {
            return "Today at \(clock)"
        }
        if let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now) {
            let yesterday = calendar.dateComponents([.year, .month, .day], from: yesterdayDate)
            if day[0] == yesterday.year, day[1] == yesterday.month, day[2] == yesterday.day {
                return "Yesterday at \(clock)"
            }
        }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard (1...12).contains(day[1]) else { return text }
        return "\(day[2]) \(months[day[1] - 1]) \(day[0]) at \(clock)"
    }

    // MARK: Icons and kinds

    /// Small symbol drawn on a well-known folder, like Finder's.
    static func folderBadgeSymbol(for name: String) -> String? {
        switch name.lowercased() {
        case "dcim", "camera": return "camera.fill"
        case "download", "downloads": return "arrow.down"
        case "pictures", "screenshots": return "photo.fill"
        case "movies": return "film.fill"
        case "music", "ringtones": return "music.note"
        case "documents": return "doc.fill"
        case "podcasts": return "mic.fill"
        case "audiobooks": return "book.fill"
        case "notifications", "alarms": return "bell.fill"
        default: return nil
        }
    }

    static func fileSymbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp": return "photo"
        case "mp4", "mov", "mkv", "webm", "3gp", "m4v": return "film"
        case "mp3", "m4a", "ogg", "opus", "flac", "wav", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "apk": return "shippingbox"
        case "txt", "md", "log", "json", "csv": return "doc.plaintext"
        default: return "doc"
        }
    }

    static func kind(for entry: PhoneFileEntry) -> String {
        switch entry.kind {
        case .directory: return "Folder"
        case .symlink: return "Alias"
        case .other: return "Item"
        case .file: break
        }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "JPEG image"
        case "png", "gif", "heic", "webp", "bmp": return "\(ext.uppercased()) image"
        case "mp4", "mov", "mkv", "webm", "3gp", "m4v": return "\(ext.uppercased()) video"
        case "mp3", "m4a", "ogg", "opus", "flac", "wav", "aac": return "\(ext.uppercased()) audio"
        case "pdf": return "PDF document"
        case "apk": return "Android app"
        case "zip", "rar", "7z", "tar", "gz": return "\(ext.uppercased()) archive"
        case "": return "File"
        default: return "\(ext.uppercased()) file"
        }
    }

    static func isHidden(_ entry: PhoneFileEntry) -> Bool {
        entry.name.hasPrefix(".")
    }

    // MARK: Storage

    enum StorageLevel: Equatable {
        case normal, low, almostFull
    }

    static func usedFraction(_ storage: PhoneStorageInfo) -> Double {
        guard storage.totalBytes > 0 else { return 0 }
        let used = Double(storage.totalBytes - storage.freeBytes) / Double(storage.totalBytes)
        return min(max(used, 0), 1)
    }

    static func storageLevel(_ storage: PhoneStorageInfo) -> StorageLevel {
        let used = usedFraction(storage)
        if used >= 0.92 { return .almostFull }
        if used >= 0.8 { return .low }
        return .normal
    }

    /// "5.2 GB free of 113.3 GB", one decimal on both sides.
    static func storageSummary(_ storage: PhoneStorageInfo) -> String {
        "\(gigabytes(storage.freeBytes)) free of \(gigabytes(storage.totalBytes))"
    }

    /// One decimal, decimal units like Finder: "113.3 GB", "5.2 GB", "640 MB".
    static func gigabytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        return String(format: "%.0f KB", value / 1_000)
    }

    static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}
