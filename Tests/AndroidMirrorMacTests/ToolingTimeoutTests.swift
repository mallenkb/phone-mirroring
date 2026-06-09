import XCTest
@testable import AndroidMirrorMac

final class ToolingTimeoutTests: XCTestCase {
    func testADBConnectCommandsAreSerialized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
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
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
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
}
