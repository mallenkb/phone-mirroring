import Foundation

enum MediaCaptureService {
    enum ScreenshotError: Error, Equatable {
        case adbMissing
        case emptyOutput
        case commandFailed(String)
    }

    static let outputFolderName = "Downloads"
    private static let screenshotTimeout: TimeInterval = 10

    static func captureScreenshot(serial: String?) -> Result<URL, ScreenshotError> {
        let result = Tooling.runDataResult(
            "adb",
            arguments: adbDeviceArguments(serial: serial) + ["exec-out", "screencap", "-p"],
            timeout: screenshotTimeout
        )

        guard result.launched else {
            return .failure(.adbMissing)
        }
        guard !result.timedOut, result.exitCode == 0 else {
            let message = result.timedOut
                ? "adb timed out after \(Int(screenshotTimeout))s while capturing the screen."
                : "adb exited with status \(result.exitCode) while capturing the screen."
            return .failure(.commandFailed(message))
        }
        guard !result.data.isEmpty else {
            return .failure(.emptyOutput)
        }

        do {
            let directory = try outputDirectory()
            let url = directory.appendingPathComponent(filename(
                kind: "Screenshot",
                extension: "png"
            ))
            try result.data.write(to: url)
            return .success(url)
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    static func outputDirectory(fileManager: FileManager = .default) throws -> URL {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(outputFolderName, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func filename(kind: String, extension fileExtension: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Android-Mirroring-\(kind)_\(formatter.string(from: date)).\(fileExtension)"
    }

    private static func adbDeviceArguments(serial: String?) -> [String] {
        guard let serial, !serial.isEmpty else { return [] }
        return ["-s", serial]
    }
}
