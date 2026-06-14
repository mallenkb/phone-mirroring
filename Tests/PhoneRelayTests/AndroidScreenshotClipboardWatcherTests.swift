import XCTest
@testable import PhoneRelay

final class AndroidScreenshotClipboardWatcherTests: XCTestCase {
    func testLatestScreenshotParserChoosesNewestScreenshotFile() {
        let output = """
        1781452722.660841558 /sdcard/DCIM/Screenshots/Screenshot_20260614_155842_WhatsApp.png
        1781475074.448688070 /sdcard/DCIM/Screenshots/Screenshot_20260614_221113_Telegram.png
        not-a-row
        1781474325.0 /sdcard/Pictures/PhoneRelay/Android-Mirroring-Clipboard_2026-06-14_21-58-45.png
        """

        let screenshot = AndroidScreenshotClipboardWatcher.latestScreenshot(from: output)

        XCTAssertEqual(screenshot?.modifiedTime, 1_781_475_074.448688)
        XCTAssertEqual(screenshot?.path, "/sdcard/DCIM/Screenshots/Screenshot_20260614_221113_Telegram.png")
    }

    func testLatestScreenshotParserIgnoresNonScreenshotImages() {
        let output = """
        1781474325.0 /sdcard/Pictures/PhoneRelay/Android-Mirroring-Clipboard_2026-06-14_21-58-45.png
        1781467130.176688070 /sdcard/Pictures/.thumbnails/1001063964.jpg
        """

        XCTAssertNil(AndroidScreenshotClipboardWatcher.latestScreenshot(from: output))
    }

    func testDefaultPollIntervalIsFastEnoughForClipboardFeel() {
        XCTAssertLessThanOrEqual(AndroidScreenshotClipboardWatcher.defaultPollIntervalNanoseconds, 750_000_000)
    }
}
