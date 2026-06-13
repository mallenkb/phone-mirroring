import Foundation

enum AboutDocument {
    case privacyPolicy
    case support
    case projectLicense
    case thirdPartyNotices
    case scrcpyApacheLicense

    var url: URL? {
        if let bundledURL = Bundle.module.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) {
            return bundledURL
        }

        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(fallbackRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private var resourceName: String {
        switch self {
        case .privacyPolicy:
            "PRIVACY_POLICY"
        case .support:
            "SUPPORT"
        case .projectLicense:
            "PHONERELAY_LICENSE"
        case .thirdPartyNotices:
            "THIRD_PARTY_NOTICES"
        case .scrcpyApacheLicense:
            "scrcpy-APACHE-2.0"
        }
    }

    private var fileExtension: String {
        "txt"
    }

    private var subdirectory: String {
        switch self {
        case .scrcpyApacheLicense:
            "About/LICENSES"
        default:
            "About"
        }
    }

    private var fallbackRelativePath: String {
        switch self {
        case .privacyPolicy:
            "Sources/PhoneRelay/Resources/About/PRIVACY_POLICY.txt"
        case .support:
            "Sources/PhoneRelay/Resources/About/SUPPORT.txt"
        case .projectLicense:
            "Sources/PhoneRelay/Resources/About/PHONERELAY_LICENSE.txt"
        case .thirdPartyNotices:
            "Sources/PhoneRelay/Resources/About/THIRD_PARTY_NOTICES.txt"
        case .scrcpyApacheLicense:
            "Sources/PhoneRelay/Resources/About/LICENSES/scrcpy-APACHE-2.0.txt"
        }
    }
}
