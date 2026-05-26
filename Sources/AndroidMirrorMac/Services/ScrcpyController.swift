import Foundation
import AppKit
import ApplicationServices

/// Lifecycle wrapper around the `scrcpy` subprocess plus the AX/CGS helpers
/// needed to find and resize its window.
@MainActor
final class ScrcpyController {
    private var process: Process?
    private(set) var activePid: pid_t?

    nonisolated static let chromeArguments = [
        "--background-color=05070A",
        "--turn-screen-off",
        "--stay-awake",
        "--max-size=1600",
        "--video-bit-rate=8M",
        "--window-width=520",
        "--window-borderless"
    ]

    var isRunning: Bool { process?.isRunning ?? false }

    /// Launches scrcpy with the given extra arguments (the chrome args are
    /// always prepended). `onTerminate` is delivered on the main actor with
    /// scrcpy's combined stdout/stderr output.
    func launch(extraArguments: [String], onTerminate: @escaping @MainActor (String) -> Void) throws -> pid_t {
        guard let path = Tooling.toolPath(named: "scrcpy") else {
            throw NSError(domain: "ScrcpyController", code: 1, userInfo: [NSLocalizedDescriptionKey: "scrcpy is missing. Install or bundle scrcpy before mirroring."])
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Self.chromeArguments + extraArguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { _ in
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                onTerminate(output)
            }
        }

        try process.run()
        self.process = process
        self.activePid = process.processIdentifier
        return process.processIdentifier
    }

    func stop() {
        process?.terminate()
        process = nil
        activePid = nil
    }

    func clear() {
        process = nil
        activePid = nil
    }

    /// Finds the largest on-screen scrcpy-owned window for the given pid.
    nonisolated static func windowBounds(pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: CGRect?
        var bestArea: CGFloat = 0

        for info in windows {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }

            let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t
            guard ownerPid == pid else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if rect.width < 80 || rect.height < 80 { continue }

            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                best = rect
            }
        }

        return best
    }

    /// Asks AX to resize scrcpy's window. Returns the AX error code so callers
    /// can decide whether to surface a "trust prompt needed" message.
    nonisolated static func setWindowFrame(pid: pid_t, frame: CGRect) -> AXError {
        let (window, windowError) = firstWindowElement(pid: pid)
        guard let window else { return windowError }

        var position = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return .failure
        }

        let positionError = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeError = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )

        if sizeError != AXError.success {
            return sizeError
        }
        return positionError
    }

    nonisolated static func setWindowMinimized(pid: pid_t, minimized: Bool) -> AXError {
        let (window, windowError) = firstWindowElement(pid: pid)
        guard let window else { return windowError }

        let value = minimized as CFBoolean
        return AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            value
        )
    }

    private nonisolated static func firstWindowElement(pid: pid_t) -> (AXUIElement?, AXError) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let copyError = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard copyError == AXError.success else { return (nil, copyError) }
        guard let windows = windowsValue as? [AXUIElement],
              let window = windows.first else {
            return (nil, AXError.failure)
        }
        return (window, AXError.success)
    }

    nonisolated static func requestAccessibilityTrustIfNeeded() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
