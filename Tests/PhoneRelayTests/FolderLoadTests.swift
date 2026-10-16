import XCTest
@testable import PhoneRelay

final class FolderLoadTests: XCTestCase {
    private let ls = PhoneFileBrowserService.listingMarker
    private let df = PhoneFileBrowserService.storageMarker

    private func output(resolved: String, listing: String, status: Int = 0) -> String {
        """
        \(resolved)
        \(ls)
        \(listing)
        \(ls) \(status)
        \(df)
        Filesystem     1K-blocks      Used Available Use% Mounted on
        /dev/fuse      110626816 105604260   4891484  96% /storage/emulated
        """
    }

    private let sampleListing = """
        total 98102
        drwxrws---  3 10254 1023     3452 2026-10-16 13:16 DCIM
        -rw-rw----  1 10254 1023  1526811 2026-07-02 12:12 notes.txt
        """

    func testParsesListingAndStorageFromOneOutput() throws {
        let load = try XCTUnwrap(PhoneFileBrowserService.parseFolderLoad(
            output(resolved: "/storage/emulated/0", listing: sampleListing)
        ))
        XCTAssertEqual(load.resolvedPath, "/storage/emulated/0")
        XCTAssertEqual(try load.listing.get().entries.map(\.name), ["DCIM", "notes.txt"])
        XCTAssertEqual(load.storage, PhoneStorageInfo(totalBytes: 110626816 * 1024, freeBytes: 4891484 * 1024))
    }

    func testRejectsResolvedPathOutsideSharedStorage() {
        XCTAssertNil(PhoneFileBrowserService.parseFolderLoad(output(resolved: "/data/data", listing: sampleListing)))
        XCTAssertNil(PhoneFileBrowserService.parseFolderLoad("/sdcard\n"))
    }

    func testPartialPermissionErrorsStillListTheRest() throws {
        let listing = sampleListing + "\nls: /storage/emulated/0/secret: Permission denied"
        let load = try XCTUnwrap(PhoneFileBrowserService.parseFolderLoad(
            output(resolved: "/sdcard", listing: listing, status: 1)
        ))
        XCTAssertEqual(try load.listing.get().entries.count, 2)
    }

    func testFailedListingReportsTheShellError() throws {
        let load = try XCTUnwrap(PhoneFileBrowserService.parseFolderLoad(
            output(resolved: "/sdcard/Gone", listing: "ls: /sdcard/Gone/: No such file or directory", status: 1)
        ))
        XCTAssertEqual(load.listing, .failure(.operationFailed("ls: /sdcard/Gone/: No such file or directory")))
    }

    func testScriptQuotesPathAndChecksResolvedTarget() {
        let script = PhoneFileBrowserService.folderLoadScript(path: "/sdcard/it's here")
        XCTAssertTrue(script.contains(#"readlink -f '/sdcard/it'\''s here'"#))
        XCTAssertTrue(script.contains(#"case "$r" in /sdcard|/sdcard/*|/storage|/storage/*)"#))
        XCTAssertTrue(script.contains(#"ls -l -a -n "$r/""#))
    }

    func testCacheEvictsOldestAndForgetsOtherPhones() {
        var cache = FolderListingCache(limit: 2)
        let entry = PhoneFileEntry(name: "a", kind: .file, sizeBytes: 1, modifiedText: "", symlinkTarget: nil)
        cache.store([entry], serial: "one", path: "/sdcard")
        cache.store([], serial: "one", path: "/sdcard/DCIM")
        cache.store([], serial: "one", path: "/sdcard")
        cache.store([], serial: "one", path: "/sdcard/Download")
        XCTAssertNil(cache.entries(serial: "one", path: "/sdcard/DCIM"))
        XCTAssertNotNil(cache.entries(serial: "one", path: "/sdcard"))
        XCTAssertNil(cache.entries(serial: "two", path: "/sdcard"))
        cache.store([], serial: "two", path: "/sdcard/Music")
        XCTAssertNil(cache.entries(serial: "one", path: "/sdcard"))
    }

    func testSortKeepsFoldersFirstForEveryField() {
        let entries = [
            PhoneFileEntry(name: "b.jpg", kind: .file, sizeBytes: 5, modifiedText: "2026-01-02 10:00", symlinkTarget: nil),
            PhoneFileEntry(name: "Zeta", kind: .directory, sizeBytes: 1, modifiedText: "2026-01-01 10:00", symlinkTarget: nil),
            PhoneFileEntry(name: "a.jpg", kind: .file, sizeBytes: 9, modifiedText: "2026-01-03 10:00", symlinkTarget: nil),
        ]
        XCTAssertEqual(FileBrowserPresentation.sorted(entries, by: .name, ascending: true).map(\.name), ["Zeta", "a.jpg", "b.jpg"])
        XCTAssertEqual(FileBrowserPresentation.sorted(entries, by: .size, ascending: false).map(\.name), ["Zeta", "a.jpg", "b.jpg"])
        XCTAssertEqual(FileBrowserPresentation.sorted(entries, by: .modified, ascending: true).map(\.name), ["Zeta", "b.jpg", "a.jpg"])
    }
}
