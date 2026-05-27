import Foundation

/// Runs scrcpy in audio-only mode beside the native video/control mirror.
/// This lets scrcpy own audio decoding/output while our AppKit window keeps
/// owning video rendering and input injection.
final class ScrcpyAudioRelay {
    private let serial: String?
    private var process: Process?
    private var outputPipe: Pipe?
    private var enabled = true

    init(serial: String?) {
        self.serial = serial
    }

    func startIfEnabled() {
        guard enabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        outputPipe = nil
    }

    private func start() {
        guard process?.isRunning != true else { return }
        guard let path = Tooling.toolPath(named: "scrcpy") else {
            Logger.log("ScrcpyAudioRelay could not start: scrcpy is missing")
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)

        var args: [String] = []
        if let serial, !serial.isEmpty {
            args += ["-s", serial]
        }
        args += [
            "--no-video",
            "--no-control",
            "--audio-source=output",
            "--audio-codec=opus",
            "--audio-buffer=80",
            "--audio-output-buffer=10"
        ]
        process.arguments = args
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { proc in
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            Logger.log("ScrcpyAudioRelay exited code=\(proc.terminationStatus) output=\(output.prefix(400))")
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            Logger.log("ScrcpyAudioRelay started with \(args.joined(separator: " "))")
        } catch {
            Logger.log("ScrcpyAudioRelay failed to start: \(error.localizedDescription)")
        }
    }
}
