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
final class ScrcpyServerHost {
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

    private let options: Options
    private var process: Process?
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
        let pushOut = Tooling.run("adb", arguments: pushArgs)
        if pushOut.localizedCaseInsensitiveContains("error") {
            throw HostError.adbCommandFailed(stage: "adb push", output: pushOut)
        }

        let scidHex = String(format: "%08x", options.scid)
        let socketName = "scrcpy_\(scidHex)"
        let reverseArgs = adbBaseArgs() + [
            "reverse", "localabstract:\(socketName)", "tcp:\(options.localPort)"
        ]
        let reverseOut = Tooling.run("adb", arguments: reverseArgs)
        if reverseOut.localizedCaseInsensitiveContains("error") {
            throw HostError.adbCommandFailed(stage: "adb reverse", output: reverseOut)
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
            self?.stdoutBuffer += line
            Logger.log("[scrcpy-server stdout] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.stderrBuffer += line
            Logger.log("[scrcpy-server stderr] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let combined = self.stdoutBuffer + self.stderrBuffer
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus, combined)
        }

        try process.run()
        self.process = process
    }

    static func serverArguments(for options: Options) -> [String] {
        let scidHex = String(format: "%08x", options.scid)
        var args = [
            "shell",
            "CLASSPATH=\(Self.devicePath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            Self.serverVersion,
            "scid=\(scidHex)",
            "log_level=info",
            "audio=\(options.audio ? "true" : "false")",
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

        if options.audio {
            // Raw PCM (48 kHz / stereo / s16le) so the Mac can play it without
            // decoding. `output` = Android playback capture (Android 11+).
            // If the device can't capture, the server sends codec-id 0 on the
            // audio socket and keeps streaming video — handled client-side.
            args += [
                "audio_codec=raw",
                "audio_source=output"
            ]
        }

        return args
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
}
