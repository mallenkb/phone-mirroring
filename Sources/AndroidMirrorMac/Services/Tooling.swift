import Foundation

/// Discovery + execution of bundled or Homebrew CLI tools (adb, scrcpy).
enum Tooling {
    static func toolPath(named name: String) -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path(percentEncoded: false),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path(percentEncoded: false),
            localScrcpyBuildPath(toolName: name),
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// During `swift run` the bundled `dist/.app` isn't used, so the brewed
    /// scrcpy would be picked up instead of the customized build in
    /// `scrcpy-source/build-mac/app/`. Walk up from the executable until we
    /// find a sibling `scrcpy-source/build-mac/app/<name>` and prefer it.
    private static func localScrcpyBuildPath(toolName: String) -> String? {
        guard toolName == "scrcpy" else { return nil }
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = url
                .appendingPathComponent("scrcpy-source")
                .appendingPathComponent("build-mac/app/\(toolName)")
                .path(percentEncoded: false)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
            url = url.deletingLastPathComponent()
            if url.path == "/" { break }
        }
        return nil
    }

    /// Path to the `scrcpy-server` dex/jar shipped in the app bundle. The
    /// in-process renderer pushes this to the phone via `adb push`.
    static func scrcpyServerPath() -> String? {
        let bundledMacOSPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/scrcpy-server")
            .path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: bundledMacOSPath) {
            return bundledMacOSPath
        }

        if let url = Bundle.module.url(forResource: "scrcpy-server", withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        // Fallback for `swift run` and unit tests — walk up to the repo root.
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidates = [
                url.appendingPathComponent("Sources/AndroidMirrorMac/Resources/scrcpy-server"),
                url.appendingPathComponent("scrcpy-source/build-mac/server/scrcpy-server")
            ]
            for candidate in candidates {
                let path = candidate.path(percentEncoded: false)
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            url = url.deletingLastPathComponent()
            if url.path == "/" { break }
        }
        return nil
    }

    static func run(_ name: String, arguments: [String]) -> String {
        guard let path = toolPath(named: name) else {
            return "\(name) is missing. Install or bundle \(name)."
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Failed to run \(name): \(error.localizedDescription)"
        }
    }

    static func runInteractive(_ name: String, arguments: [String], input: String) -> String {
        guard let path = toolPath(named: name) else {
            return "\(name) is missing. Install or bundle \(name)."
        }

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Failed to run \(name): \(error.localizedDescription)"
        }
    }
}

enum Logger {
    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        let logPath = NSString(string: "~/Library/Logs/AndroidMirrorMac.log").expandingTildeInPath
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }
}
