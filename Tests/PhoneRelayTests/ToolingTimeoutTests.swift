import XCTest
@testable import PhoneRelay

final class ToolingTimeoutTests: XCTestCase {
    func testADBConnectCommandsAreSerialized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        let script = """
        #!/bin/sh
        if [ "$1" = "connect" ]; then
          echo "start $2 $(date +%s%N)" >> "$ADB_FAKE_LOG"
          sleep 1
          echo "end $2 $(date +%s%N)" >> "$ADB_FAKE_LOG"
          echo "connected to $2"
          exit 0
        fi
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)

        async let first = Task.detached {
            ADBController().run(["connect", "192.0.2.53:5555"], timeout: 3)
        }.value
        async let second = Task.detached {
            ADBController().run(["connect", "192.0.2.54:5555"], timeout: 3)
        }.value
        _ = await [first, second]

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("start "))
        XCTAssertTrue(lines[1].hasPrefix("end "))
        XCTAssertTrue(lines[2].hasPrefix("start "))
        XCTAssertTrue(lines[3].hasPrefix("end "))
    }

    func testADBTimeoutKillsProcessThatIgnoresGracefulSignals() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        trap '' TERM INT
        while true; do sleep 1; done
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let output = ADBController().run(["connect", "192.0.2.53:5555"], timeout: 0.5)

        XCTAssertTrue(output.contains("adb timed out after 0s"))
        Thread.sleep(forTimeInterval: 0.1)
        let lingering = Tooling.run("pgrep", arguments: ["-f", fakeADB.path], timeout: 1)
        XCTAssertTrue(lingering.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCommandWordSkipsOptionFlagsAndSerials() {
        XCTAssertEqual(ADBController.commandWord(in: ["connect", "192.0.2.5:5555"]), "connect")
        XCTAssertEqual(ADBController.commandWord(in: ["-s", "RFTEST", "tcpip", "5555"]), "tcpip")
        XCTAssertEqual(ADBController.commandWord(in: ["-s", "RFTEST", "shell", "echo", "ok"]), "shell")
        XCTAssertEqual(ADBController.commandWord(in: ["devices", "-l"]), "devices")
        XCTAssertNil(ADBController.commandWord(in: []))

        XCTAssertTrue(ADBController.serializedCommands.contains("connect"))
        XCTAssertFalse(ADBController.serializedCommands.contains("devices"))
        XCTAssertFalse(ADBController.serializedCommands.contains("shell"))
    }

    // The device watcher's `devices -l` poll must not queue behind a slow
    // `connect` to an unreachable address — that lag is what made USB
    // plug-in detection feel slow.
    func testDevicesPollIsNotBlockedBehindSlowConnect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        if [ "$1" = "connect" ]; then
          sleep 2
          echo "connected to $2"
          exit 0
        fi
        echo "List of devices attached"
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let connectTask = Task.detached {
            ADBController().run(["connect", "192.0.2.53:5555"], timeout: 4)
        }
        // Give the connect a head start so it holds the serialized lock.
        try await Task.sleep(nanoseconds: 300_000_000)

        let start = Date()
        _ = await Task.detached {
            ADBController().run(["devices", "-l"], timeout: 4)
        }.value
        let devicesLatency = Date().timeIntervalSince(start)

        _ = await connectTask.value
        // Serialized behind the 2s connect this would be ≥1.7s; unblocked it is
        // a single process spawn. The wide margin absorbs CI scheduler noise.
        XCTAssertLessThan(devicesLatency, 1.2, "devices poll waited behind the connect lock")
    }

    // The binary-output runner backs notification-banner screenshots on a
    // serial queue; a child that never exits must time out, not wedge it.
    func testRunDataResultTimesOutAndKillsSilentChild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        trap '' TERM INT
        while true; do sleep 1; done
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let result = Tooling.runDataResult(
            "adb",
            arguments: ["exec-out", "screencap", "-p"],
            timeout: 0.5
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        Thread.sleep(forTimeInterval: 0.1)
        let lingering = Tooling.run("pgrep", arguments: ["-f", fakeADB.path], timeout: 1)
        XCTAssertTrue(lingering.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // The suite must never append fixture data to the shipping app's log file
    // (`~/Library/Logs/PhoneRelay.log`) — doing so polluted live handoff debugging
    // with test-only device serials and RFC5737 doc-IPs.
    func testFileLoggingIsRedirectedAwayFromShippingLogUnderXCTest() {
        let shippingPath = NSString(string: "~/Library/Logs/PhoneRelay.log").expandingTildeInPath

        XCTAssertTrue(Logger.isRunningUnderXCTest)
        XCTAssertNotEqual(Logger.logURL.path, shippingPath)

        // A log call from a test must land in the redirected temp file, not the
        // shipping log. Snapshot the shipping log size, log, and confirm it is
        // untouched while the temp file receives the line.
        let fm = FileManager.default
        let sizeBefore = (try? fm.attributesOfItem(atPath: shippingPath)[.size] as? UInt64) ?? nil

        let marker = "xctest-redirect-marker-\(UUID().uuidString)"
        Logger.log(marker)
        // `Logger.log` writes on a private serial queue; drain it before reading.
        Logger.flushForTesting()

        let sizeAfter = (try? fm.attributesOfItem(atPath: shippingPath)[.size] as? UInt64) ?? nil
        XCTAssertEqual(sizeBefore, sizeAfter, "test logging grew the shipping app log file")

        let redirected = (try? String(contentsOf: Logger.logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(redirected.contains(marker), "marker did not reach the redirected temp log")
    }

    func testRunDataResultKeepsStdoutFreeOfStderrNoise() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        echo "daemon warning noise" >&2
        printf 'PNGBYTES'
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)

        let result = Tooling.runDataResult(
            "adb",
            arguments: ["exec-out", "screencap", "-p"],
            timeout: 3
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "PNGBYTES")
    }
}
