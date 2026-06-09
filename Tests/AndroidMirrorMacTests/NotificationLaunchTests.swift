import XCTest
@testable import AndroidMirrorMac

final class NotificationLaunchTests: XCTestCase {
    func testLaunchSourceAppArgumentsTargetSelectedSerialAndPackage() {
        XCTAssertEqual(
            AppModel.launchSourceAppArguments(serial: "ABC123", package: "com.whatsapp"),
            [
                "-s", "ABC123",
                "shell",
                "monkey",
                "-p", "com.whatsapp",
                "-c", "android.intent.category.LAUNCHER",
                "1"
            ]
        )
    }
}
