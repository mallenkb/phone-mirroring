import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Pulls and caches gallery thumbnails for phone images. Downscales to
/// 256px, keys the disk cache by serial+path+size+mtime (so an edited photo
/// re-pulls), and caps concurrent adb pulls so browsing DCIM can't saturate
/// the same link the mirror stream uses.
final class PhoneThumbnailStore: @unchecked Sendable {

    static let shared = PhoneThumbnailStore()

    private let memoryCache = NSCache<NSString, NSData>()
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
    func thumbnailPNGData(serial: String, directory: String, entry: PhoneFileEntry) -> Data? {
        guard Self.isThumbnailable(entry) else { return nil }
        let remotePath = PhoneFileBrowserService.joined(directory, entry.name)
        let key = Self.cacheKey(serial: serial, remotePath: remotePath, entry: entry)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached as Data
        }
        let diskURL = diskDirectory.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: diskURL), Self.isDecodableImageData(data) {
            memoryCache.setObject(data as NSData, forKey: key as NSString)
            return data
        }

        concurrencyGate.wait()
        defer { concurrencyGate.signal() }
        // Another waiter may have produced it while this one was queued.
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached as Data
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
            let thumbnailData = Self.downscaledPNGData(pulled)
        else { return nil }

        try? thumbnailData.write(to: diskURL, options: .atomic)
        memoryCache.setObject(thumbnailData as NSData, forKey: key as NSString)
        return thumbnailData
    }

    nonisolated static func downscaledPNGData(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated private static func isDecodableImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
