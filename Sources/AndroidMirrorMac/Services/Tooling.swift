import Foundation

/// Discovery + execution of bundled or Homebrew CLI tools (adb, scrcpy).
enum Tooling {
    static func toolPath(named name: String) -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path(percentEncoded: false),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path(percentEncoded: false),
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
