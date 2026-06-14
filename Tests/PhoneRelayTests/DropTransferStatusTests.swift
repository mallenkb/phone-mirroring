import XCTest
@testable import PhoneRelay

final class DropTransferStatusTests: XCTestCase {
    @MainActor
    func testDroppingAPKShowsInstallingStatusUntilInstallCompletes() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        sleep 0.2
        echo "Success"
        exit 0
        """)
        defer { fake.cleanup() }

        let apk = try temporaryFile(named: "Example.apk")
        defer { try? FileManager.default.removeItem(at: apk) }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.selectedDevice = MirrorDevice(
            id: "adb-test",
            name: "Test Phone",
            model: "Test Phone",
            battery: 80,
            isCharging: false,
            network: "USB debugging",
            lastSeen: .now,
            states: [.mirroringReady],
            adbSerial: "TESTSERIAL"
        )

        model.handleDroppedFiles([apk])

        let installing = try await waitForTransferActivity(in: model) { activity in
            activity?.phase == .installing
        }
        XCTAssertEqual(installing.title, "Installing APK")
        XCTAssertEqual(installing.detail, "Example.apk")

        let completed = try await waitForTransferActivity(in: model) { activity in
            activity?.phase == .completed
        }
        XCTAssertEqual(completed.title, "Installed 1 app")
        XCTAssertEqual(loggedCalls(fake.log), ["-s TESTSERIAL install -r \(apk.path)"])
    }

    private func waitForTransferActivity(
        in model: AppModel,
        matching predicate: @MainActor (AppModel.TransferActivity?) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppModel.TransferActivity {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < 2 {
            if await predicate(model.transferActivity), let activity = await model.transferActivity {
                return activity
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for transfer activity", file: file, line: line)
        throw TestError.timeout
    }

    private func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("apk".utf8).write(to: file)
        return file
    }

    private func installFakeADB(script: String) throws -> (log: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)
        return (log, {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
        })
    }

    private func loggedCalls(_ log: URL) -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
    }

    private enum TestError: Error {
        case timeout
    }
}
