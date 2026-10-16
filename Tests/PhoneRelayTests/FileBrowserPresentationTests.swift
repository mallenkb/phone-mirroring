import XCTest
@testable import PhoneRelay

final class FileBrowserPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15))!
    }

    func testFriendlyDates() {
        XCTAssertEqual(FileBrowserPresentation.friendlyDate("2026-10-16 13:16", now: now, calendar: calendar), "Today at 13:16")
        XCTAssertEqual(FileBrowserPresentation.friendlyDate("2026-10-15 20:43", now: now, calendar: calendar), "Yesterday at 20:43")
        XCTAssertEqual(FileBrowserPresentation.friendlyDate("2026-07-09 20:43", now: now, calendar: calendar), "9 Jul 2026 at 20:43")
        XCTAssertEqual(FileBrowserPresentation.friendlyDate("2023-02-27 08:18:42", now: now, calendar: calendar), "27 Feb 2023 at 08:18")
        XCTAssertEqual(FileBrowserPresentation.friendlyDate("garbage", now: now, calendar: calendar), "garbage")
    }

    func testPathSegmentsStartAtInternalStorage() {
        XCTAssertEqual(
            FileBrowserPresentation.pathSegments(for: "/sdcard/DCIM/Camera").map(\.title),
            ["Internal storage", "DCIM", "Camera"]
        )
        XCTAssertEqual(FileBrowserPresentation.pathSegments(for: "/sdcard/DCIM/Camera").map(\.path),
                       ["/sdcard", "/sdcard/DCIM", "/sdcard/DCIM/Camera"])
        XCTAssertEqual(FileBrowserPresentation.title(for: "/sdcard"), "Internal storage")
    }

    func testKindsAndBadges() {
        func file(_ name: String) -> PhoneFileEntry { .init(name: name, kind: .file, sizeBytes: 1, modifiedText: "") }
        XCTAssertEqual(FileBrowserPresentation.kind(for: file("IMG_1.jpg")), "JPEG image")
        XCTAssertEqual(FileBrowserPresentation.kind(for: file("VID.mp4")), "MP4 video")
        XCTAssertEqual(FileBrowserPresentation.kind(for: file("app.apk")), "Android app")
        XCTAssertEqual(FileBrowserPresentation.kind(for: .init(name: "DCIM", kind: .directory, modifiedText: "")), "Folder")
        XCTAssertEqual(FileBrowserPresentation.folderBadgeSymbol(for: "DCIM"), "camera.fill")
        XCTAssertNil(FileBrowserPresentation.folderBadgeSymbol(for: "google.com!x"))
        XCTAssertTrue(FileBrowserPresentation.isHidden(.init(name: ".wallpaper", kind: .directory, modifiedText: "")))
    }

    func testStorageLevels() {
        let full = PhoneStorageInfo(totalBytes: 113_280_000_000, freeBytes: 5_200_000_000)
        XCTAssertEqual(FileBrowserPresentation.storageLevel(full), .almostFull)
        XCTAssertEqual(FileBrowserPresentation.storageLevel(PhoneStorageInfo(totalBytes: 100, freeBytes: 15)), .low)
        XCTAssertEqual(FileBrowserPresentation.storageLevel(PhoneStorageInfo(totalBytes: 100, freeBytes: 60)), .normal)
        XCTAssertEqual(FileBrowserPresentation.usedFraction(PhoneStorageInfo(totalBytes: 0, freeBytes: 0)), 0)
        XCTAssertEqual(FileBrowserPresentation.storageSummary(full), "5.2 GB free of 113.3 GB")
    }

    func testScreenshotsPlaceTriesSamsungThenPixelPaths() {
        let place = FileBrowserPlace.all.first { $0.id == "screenshots" }
        XCTAssertEqual(place?.paths, ["/sdcard/DCIM/Screenshots", "/sdcard/Pictures/Screenshots"])
        XCTAssertEqual(FileBrowserPlace.current(for: "/sdcard/Download")?.id, "downloads")
    }
}

@MainActor
final class FileBrowserNavigationTests: XCTestCase {
    func testBackAndForwardFollowHistoryAndSearchClears() {
        let model = FileBrowserModel(serialProvider: { nil })
        model.searchText = "dc"
        model.navigate(to: "/sdcard/DCIM")
        XCTAssertEqual(model.path, "/sdcard/DCIM")
        XCTAssertEqual(model.searchText, "")
        model.navigate(to: "/sdcard/Download")
        model.goBack()
        XCTAssertEqual(model.path, "/sdcard/DCIM")
        XCTAssertTrue(model.canGoForward)
        model.goForward()
        XCTAssertEqual(model.path, "/sdcard/Download")
        model.goBack(); model.goBack()
        XCTAssertEqual(model.path, "/sdcard")
        XCTAssertFalse(model.canGoBack)
    }

    func testNavigationStaysInsideSharedStorage() {
        let model = FileBrowserModel(serialProvider: { nil })
        model.navigate(to: "/data/data")
        XCTAssertEqual(model.path, "/sdcard")
    }
}
