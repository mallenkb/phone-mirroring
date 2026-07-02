import AppKit
import CryptoKit
import ImageIO

/// Pulls and caches gallery thumbnails for phone images. Downscales to
/// 256px, keys the disk cache by serial+path+size+mtime (so an edited photo
/// re-pulls), and caps concurrent adb pulls so browsing DCIM can't saturate
/// the same link the mirror stream uses.
final class PhoneThumbnailStore: @unchecked Sendable {

    static let shared = PhoneThumbnailStore()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let concurrencyGate = DispatchSemaphore(value: 3)
    private let diskDirectory: URL

    nonisolated static let thumbnailableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff"
    ]
    /// Originals above this size aren't worth pulling just for a thumbnail.
    nonisolated static let maxSourceBytes: Int64 = 30 * 1024 * 1024
    nonisolated static let thumbnailPixelSize = 256

    private init() {
        memoryCache.countLimit = 512
        diskDirectory = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("PhoneRelay Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    nonisolated static func isThumbnailable(_ entry: PhoneFileEntry) -> Bool {
        guard entry.kind == .file,
              let size = entry.sizeBytes, size <= maxSourceBytes
        else { return false }
        return thumbnailableExtensions.contains(
            ((entry.name as NSString).pathExtension).lowercased()
        )
    }

    nonisolated static func cacheKey(serial: String, remotePath: String, entry: PhoneFileEntry) -> String {
        let identity = "\(serial)|\(remotePath)|\(entry.sizeBytes ?? -1)|\(entry.modifiedText)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Blocking; call from a detached task. Returns nil when the entry isn't
    /// an image, the pull fails, or decoding fails.
    func thumbnail(serial: String, directory: String, entry: PhoneFileEntry) -> NSImage? {
        guard Self.isThumbnailable(entry) else { return nil }
        let remotePath = PhoneFileBrowserService.joined(directory, entry.name)
        let key = Self.cacheKey(serial: serial, remotePath: remotePath, entry: entry)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        let diskURL = diskDirectory.appendingPathComponent(key + ".png")
        if let image = NSImage(contentsOf: diskURL) {
            memoryCache.setObject(image, forKey: key as NSString)
            return image
        }

        concurrencyGate.wait()
        defer { concurrencyGate.signal() }
        // Another waiter may have produced it while this one was queued.
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelay Thumbnails", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )) != nil,
            case .success(let pulled) = PhoneFileBrowserService.pull(
                serial: serial, remotePath: remotePath, localDirectory: scratch
            ),
            let thumbnail = Self.downscaled(pulled)
        else { return nil }

        if let tiff = thumbnail.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: diskURL)
        }
        memoryCache.setObject(thumbnail, forKey: key as NSString)
        return thumbnail
    }

    nonisolated private static func downscaled(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
