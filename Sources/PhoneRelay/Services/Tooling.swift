import Foundation
import Darwin
import os

/// Discovery + execution of bundled or Homebrew CLI tools (adb, scrcpy).
enum Tooling {
    private static let processOutputQueue = DispatchQueue(
        label: "phonerelay.tooling.process-output",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func toolPath(named name: String) -> String? {
#if DEBUG
        if name == "adb",
           let rawOverridePath = getenv("ANDROID_MIRROR_ADB_PATH") {
            let overridePath = String(cString: rawOverridePath)
            let url = URL(fileURLWithPath: overridePath).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }
#endif

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
        if let bundledResourcePath = Bundle.main.resourceURL?
            .appendingPathComponent("scrcpy-server")
            .path(percentEncoded: false),
           FileManager.default.fileExists(atPath: bundledResourcePath) {
            return bundledResourcePath
        }

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
#if DEBUG
        // Fallback for `swift run` and unit tests — walk up to the repo root.
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidates = [
                url.appendingPathComponent("Sources/PhoneRelay/Resources/scrcpy-server"),
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
#endif
        return nil
    }

    /// Outcome of running a CLI tool. `succeeded` lets callers branch on the
    /// real process exit status instead of string-matching stdout, which is
    /// brittle against localized output and benign "error" substrings.
    struct RunResult {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
        var launched: Bool
        var succeeded: Bool { launched && !timedOut && exitCode == 0 }
    }

    /// Reference box so the background drain thread can hand the captured bytes
    /// back across the semaphore without tripping concurrency checks.
    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Runs a tool, draining stdout+stderr on a background queue (so a child
    /// that writes more than the pipe buffer can't deadlock against us while we
    /// wait for it to exit) and enforcing a hard timeout. Returns the captured
    /// output plus the real termination status.
    static func runResult(
        _ name: String,
        arguments: [String],
        timeout overrideTimeout: TimeInterval? = nil
    ) -> RunResult {
        guard let path = toolPath(named: name) else {
            return RunResult(
                output: "\(name) is missing. Install or bundle \(name).",
                exitCode: -1, timedOut: false, launched: false
            )
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        processOutputQueue.async {
            box.data = handle.readDataToEndOfFile()
            readDone.signal()
        }

        do {
            try process.run()
        } catch {
            handle.closeFile()
            readDone.signal()
            return RunResult(
                output: "Failed to run \(name): \(error.localizedDescription)",
                exitCode: -1, timedOut: false, launched: false
            )
        }

        let timeout: TimeInterval = overrideTimeout ?? (name == "adb" ? 5 : 30)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { process.interrupt() }
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()
        _ = readDone.wait(timeout: .now() + 1)
        let output = String(data: box.data, encoding: .utf8) ?? ""
        return RunResult(
            output: output,
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            launched: true
        )
    }

    /// Outcome of `runDataResult` — raw stdout bytes instead of merged text.
    struct DataRunResult {
        var data: Data
        var exitCode: Int32
        var timedOut: Bool
        var launched: Bool
        var succeeded: Bool { launched && !timedOut && exitCode == 0 }
    }

    /// Like `runResult`, but keeps stdout as raw bytes and drains stderr on a
    /// separate pipe so binary output (e.g. `adb exec-out screencap -p`) can't
    /// be corrupted by interleaved stderr text. Same hard timeout and
    /// terminate → interrupt → SIGKILL escalation as `runResult`.
    static func runDataResult(
        _ name: String,
        arguments: [String],
        timeout overrideTimeout: TimeInterval? = nil
    ) -> DataRunResult {
        guard let path = toolPath(named: name) else {
            return DataRunResult(data: Data(), exitCode: -1, timedOut: false, launched: false)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        processOutputQueue.async {
            box.data = stdoutHandle.readDataToEndOfFile()
            readDone.signal()
        }
        // stderr must be drained too, or a chatty child deadlocks on a full pipe.
        processOutputQueue.async {
            _ = stderrHandle.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            readDone.signal()
            return DataRunResult(data: Data(), exitCode: -1, timedOut: false, launched: false)
        }

        let timeout: TimeInterval = overrideTimeout ?? (name == "adb" ? 5 : 30)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { process.interrupt() }
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()
        _ = readDone.wait(timeout: .now() + 1)
        return DataRunResult(
            data: box.data,
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            launched: true
        )
    }

    static func run(_ name: String, arguments: [String], timeout overrideTimeout: TimeInterval? = nil) -> String {
        let result = runResult(name, arguments: arguments, timeout: overrideTimeout)
        if result.timedOut {
            let timeout: TimeInterval = overrideTimeout ?? (name == "adb" ? 5 : 30)
            return "\(name) timed out after \(Int(timeout))s: \(arguments.joined(separator: " "))"
        }
        return result.output
    }

    static func runInteractive(
        _ name: String,
        arguments: [String],
        input: String,
        timeout overrideTimeout: TimeInterval? = nil
    ) -> String {
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

        let handle = outputPipe.fileHandleForReading
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        processOutputQueue.async {
            box.data = handle.readDataToEndOfFile()
            readDone.signal()
        }

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            handle.closeFile()
            readDone.signal()
            return "Failed to run \(name): \(error.localizedDescription)"
        }

        // Hard timeout so a stuck `adb pair`/`adb connect` can't hang forever.
        let timeout: TimeInterval = overrideTimeout ?? 15
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = readDone.wait(timeout: .now() + 1)
            return "\(name) timed out after \(Int(timeout))s: \(arguments.joined(separator: " "))"
        }

        process.waitUntilExit()
        _ = readDone.wait(timeout: .now() + 1)
        return String(data: box.data, encoding: .utf8) ?? ""
    }
}

enum Logger {
    /// Unified-logging handle — visible in Console.app, filterable by subsystem.
    private static let osLog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.example.PhoneRelay",
        category: "app"
    )
    /// Hard cap on the on-disk log; trimmed to the most recent half when hit so
    /// it can never grow unbounded.
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024
    private static let queue = DispatchQueue(label: "phonerelay.logger")
    private static let timestampFormatter = ISO8601DateFormatter()
    static let logURL = URL(
        fileURLWithPath: NSString(string: "~/Library/Logs/PhoneRelay.log").expandingTildeInPath
    )

    static func log(_ message: String) {
        osLog.log("\(message, privacy: .public)")
        queue.async { appendToFile(message) }
    }

    private static func appendToFile(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: logURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        if handle.offsetInFile > maxLogBytes {
            handle.seek(toFileOffset: handle.offsetInFile - maxLogBytes / 2)
            let tail = handle.readDataToEndOfFile()
            handle.truncateFile(atOffset: 0)
            handle.seek(toFileOffset: 0)
            handle.write(tail)
        }
    }
}
