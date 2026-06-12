import Foundation

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var browserDownloadURL: URL
        var name: String
        var size: Int?

        enum CodingKeys: String, CodingKey {
            case browserDownloadURL = "browser_download_url"
            case name
            case size
        }
    }

    var assets: [Asset]
    var htmlURL: URL?
    var name: String?
    var tagName: String

    enum CodingKeys: String, CodingKey {
        case assets
        case htmlURL = "html_url"
        case name
        case tagName = "tag_name"
    }
}

struct GitHubReleaseUpdate {
    var release: GitHubRelease
    var version: String
    var asset: GitHubRelease.Asset
}

enum GitHubReleaseUpdaterError: LocalizedError {
    case invalidResponse
    case releaseAssetMissing
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub did not return a usable latest release response."
        case .releaseAssetMissing:
            return "The latest GitHub release does not include a PhoneRelay DMG asset."
        case .downloadFailed:
            return "The update download could not be saved."
        }
    }
}

final class GitHubReleaseUpdater {
    private let latestReleaseAPI: URL
    private let session: URLSession
    private let fileManager: FileManager

    init(
        latestReleaseAPI: URL = URL(string: "https://api.github.com/repos/mallenkb/phone-mirroring/releases/latest")!,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.latestReleaseAPI = latestReleaseAPI
        self.session = session
        self.fileManager = fileManager
    }

    func availableUpdate(currentVersion: String) async throws -> GitHubReleaseUpdate? {
        let release = try await latestRelease()
        let latestVersion = Self.normalizedVersion(release.tagName)
        guard Self.compareVersions(latestVersion, currentVersion) > 0 else {
            return nil
        }
        guard let asset = Self.preferredInstallerAsset(in: release) else {
            throw GitHubReleaseUpdaterError.releaseAssetMissing
        }
        return GitHubReleaseUpdate(release: release, version: latestVersion, asset: asset)
    }

    func download(_ update: GitHubReleaseUpdate) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: update.asset.browserDownloadURL)
        guard ((response as? HTTPURLResponse)?.statusCode).map({ 200..<300 ~= $0 }) ?? true else {
            throw GitHubReleaseUpdaterError.invalidResponse
        }

        let updatesDirectory = try updatesDirectory()
        let destination = updatesDirectory
            .appendingPathComponent("PhoneRelay-\(update.version)", isDirectory: false)
            .appendingPathExtension("dmg")

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw GitHubReleaseUpdaterError.downloadFailed
        }
        return destination
    }

    private func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PhoneRelay", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw GitHubReleaseUpdaterError.invalidResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func updatesDirectory() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("PhoneRelay", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func normalizedVersion(_ version: String?) -> String {
        guard let version else { return "0" }
        return version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
    }

    static func compareVersions(_ left: String?, _ right: String?) -> Int {
        let leftParts = normalizedVersion(left).split(separator: ".").map { Int($0) ?? 0 }
        let rightParts = normalizedVersion(right).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let difference = (index < leftParts.count ? leftParts[index] : 0)
                - (index < rightParts.count ? rightParts[index] : 0)
            if difference != 0 {
                return difference > 0 ? 1 : -1
            }
        }
        return 0
    }

    static func preferredInstallerAsset(in release: GitHubRelease) -> GitHubRelease.Asset? {
        release.assets.first { asset in
            asset.name.localizedCaseInsensitiveCompare("PhoneRelay.dmg") == .orderedSame
        } ?? release.assets.first { asset in
            asset.name.lowercased().hasSuffix(".dmg")
        }
    }
}
