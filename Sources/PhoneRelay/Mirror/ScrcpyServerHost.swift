import Foundation

/// Spawns and tears down the scrcpy server on the connected Android device.
/// Workflow:
///   1. Push the bundled `scrcpy-server` jar onto the device.
///   2. Open an `adb reverse` from a `localabstract:scrcpy_<scid>` on the
///      device back to our local TCP listener.
///   3. Run `adb shell app_process` to launch the server. The server then
///      opens local sockets for video and control, and the device routes each
///      connection to our listener.
///
/// `ScrcpyServerHost` knows nothing about parsing the stream — that's done
/// downstream by `ScrcpyVideoStream` and `ScrcpyControlChannel`.
final class ScrcpyServerHost: @unchecked Sendable {
    enum HostError: Error, CustomStringConvertible {
        case missingServerArtifact
        case missingAdb
        case adbCommandFailed(stage: String, output: String)

        var description: String {
            switch self {
            case .missingServerArtifact:
                return "scrcpy-server resource was not bundled with the app."
            case .missingAdb:
                return "adb is not on PATH and not bundled with the app."
            case .adbCommandFailed(let stage, let output):
                return "\(stage) failed: \(output)"
            }
        }
    }

    struct Options {
        var scid: UInt32
        var localPort: UInt16
        var videoBitRate: UInt32 = 8_000_000
        var maxSize: UInt16 = 1600
        var maxFps: UInt16 = 60
        var audio: Bool = false
        var serial: String?
    }

    /// scrcpy server protocol version. Must match the bundled jar.
    static let serverVersion = "4.0"
    static let devicePath = "/data/local/tmp/scrcpy-server.jar"
    private static let maxCapturedOutputCharacters = 64 * 1024
    private static let maxLoggedChunkCharacters = 4 * 1024

    private let options: Options
    private var process: Process?
    /// stdout/stderr are appended from two separate `readabilityHandler` queues
    /// and read together from the termination handler — three threads — so all
    /// access goes through `outputLock`. Concurrent `String` mutation would
    /// otherwise be undefined behavior (this class is `@unchecked Sendable`, so
    /// the compiler won't catch it).
    private let outputLock = NSLock()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var reverseInstalled = false

    init(options: Options) {
        self.options = options
    }

    /// Pushes the server jar and installs the adb-reverse tunnel. The caller
    /// must have a TCP listener already bound to `options.localPort` before
    /// calling this so the device's first connection has somewhere to land.
    func prepareTunnel() throws {
        guard let serverPath = Tooling.scrcpyServerPath() else {
            throw HostError.missingServerArtifact
        }
        guard Tooling.toolPath(named: "adb") != nil else {
            throw HostError.missingAdb
        }

        let pushArgs = adbBaseArgs() + ["push", serverPath, Self.devicePath]
        let push = Tooling.runResult("adb", arguments: pushArgs, timeout: 30)
        if !push.succeeded {
            throw HostError.adbCommandFailed(stage: "adb push", output: push.output)
        }

        let scidHex = String(format: "%08x", options.scid)
        let socketName = "scrcpy_\(scidHex)"
        let reverseArgs = adbBaseArgs() + [
            "reverse", "localabstract:\(socketName)", "tcp:\(options.localPort)"
        ]
        let reverse = Tooling.runResult("adb", arguments: reverseArgs)
        if !reverse.succeeded {
            throw HostError.adbCommandFailed(stage: "adb reverse", output: reverse.output)
        }
        reverseInstalled = true

        wakeDevice()
    }

    /// Spawns the scrcpy server with `adb shell app_process …`. Returns
    /// immediately. The server stays alive until `stop()` or the device
    /// disconnects.
    func start(onExit: @escaping (Int32, String) -> Void) throws {
        guard let adbPath = Tooling.toolPath(named: "adb") else {
            throw HostError.missingAdb
        }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)

        var args = adbBaseArgs()
        args += Self.serverArguments(for: options)
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.appendOutput(line, to: \.stdoutBuffer)
            Logger.log("[scrcpy-server stdout] \(Self.truncatedLogChunk(line))")
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.appendOutput(line, to: \.stderrBuffer)
            Logger.log("[scrcpy-server stderr] \(Self.truncatedLogChunk(line))")
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let combined = self.outputLock.withLock { self.stdoutBuffer + self.stderrBuffer }
            onExit(proc.terminationStatus, combined)
        }

        try process.run()
        self.process = process
    }

    static func serverArguments(for options: Options) -> [String] {
        let scidHex = String(format: "%08x", options.scid)
        // Keep audio aligned with upstream scrcpy defaults. Some Samsung builds
        // crash inside the device-side server when we force custom audio
        // encoder/source/bit-rate options, while upstream `scrcpy` with only
        // audio enabled works on the same phone.
        var audioArgs = ["audio=false"]
        if options.audio {
            audioArgs = ["audio=true"]
        }
        let args = [
            "shell",
            "CLASSPATH=\(Self.devicePath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            Self.serverVersion,
            "scid=\(scidHex)",
            "log_level=info",
        ] + audioArgs + [
            "video=true",
            "control=true",
            "tunnel_forward=false",
            "send_dummy_byte=false",
            "video_codec=h264",
            "video_bit_rate=\(options.videoBitRate)",
            "max_size=\(options.maxSize)",
            "max_fps=\(options.maxFps)",
            // NOTE: do NOT pass stay_awake=true. On Samsung One UI (e.g.
            // SM-S906B) the server's stay-awake path aborts with native
            // "stack corruption detected (-fstack-protector)" (exit 134),
            // killing the session right after it loads.
            "power_on=true",
            "cleanup=true"
        ]

        return args
    }

    static func isSamsungAudioStackCrash(code: Int32, output: String) -> Bool {
        code == 134
            && output.localizedCaseInsensitiveContains("stack corruption detected")
    }

    static func isRecoverableAudioStartupFailure(code: Int32, output: String) -> Bool {
        guard code != 0 else { return false }
        return isSamsungAudioStackCrash(code: code, output: output)
            || output.localizedCaseInsensitiveContains("audio")
    }

    func stop() {
        process?.terminate()
        process = nil
        // Terminating the local `adb shell` does NOT necessarily kill the
        // device-side server; a leftover process holds the encoder/display and
        // makes the next launch abort. Kill it explicitly, scoped to this scid.
        let scidHex = String(format: "%08x", options.scid)
        _ = Tooling.run("adb", arguments: adbBaseArgs() + ["shell", "pkill", "-f", "scid=\(scidHex)"], timeout: 3)
        if reverseInstalled {
            let socketName = "scrcpy_\(scidHex)"
            _ = Tooling.run("adb", arguments: adbBaseArgs() + ["reverse", "--remove", "localabstract:\(socketName)"])
            reverseInstalled = false
        }
    }

    private func adbBaseArgs() -> [String] {
        if let serial = options.serial, !serial.isEmpty {
            return ["-s", serial]
        }
        return []
    }

    private func wakeDevice() {
        let output = Tooling.run("adb", arguments: adbBaseArgs() + ["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        if output.localizedCaseInsensitiveContains("error") {
            Logger.log("adb wake failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func appendOutput(_ output: String, to keyPath: ReferenceWritableKeyPath<ScrcpyServerHost, String>) {
        outputLock.withLock {
            self[keyPath: keyPath] += output
            if self[keyPath: keyPath].count > Self.maxCapturedOutputCharacters {
                self[keyPath: keyPath] = String(self[keyPath: keyPath].suffix(Self.maxCapturedOutputCharacters))
            }
        }
    }

    private static func truncatedLogChunk(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLoggedChunkCharacters else { return trimmed }
        return "\(trimmed.prefix(maxLoggedChunkCharacters))... [truncated]"
    }
}
