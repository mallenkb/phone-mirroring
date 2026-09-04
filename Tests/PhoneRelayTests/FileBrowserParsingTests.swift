import XCTest
@testable import PhoneRelay

final class FileBrowserParsingTests: XCTestCase {

    // MARK: - parseListing

    func testParsesTypicalDirectoryAndSkipsDotEntries() {
        let output = """
        total 120
        drwxrwx--x  4 media_rw media_rw 4096 2026-07-01 09:41 .
        drwxrwx--x 30 media_rw media_rw 4096 2026-06-01 08:00 ..
        drwxrwx--x  2 media_rw media_rw 4096 2026-07-01 09:41 Camera
        -rw-rw----  1 u0_a123 media_rw 1234567 2026-06-28 18:12 report.pdf
        """
        let result = PhoneFileBrowserService.parseListing(output)

        XCTAssertEqual(result.skippedLines, 0)
        XCTAssertEqual(result.entries.map(\.name), ["Camera", "report.pdf"])
        XCTAssertEqual(result.entries[0].kind, .directory)
        XCTAssertEqual(result.entries[0].sizeBytes, 4096)
        XCTAssertEqual(result.entries[1].kind, .file)
        XCTAssertEqual(result.entries[1].sizeBytes, 1_234_567)
        XCTAssertEqual(result.entries[1].modifiedText, "2026-06-28 18:12")
    }

    func testSortsFoldersFirstThenByLocalizedName() {
        let output = """
        -rw-rw---- 1 u0_a1 media_rw 10 2026-01-01 00:00 zebra.txt
        drwxrwx--x 2 u0_a1 media_rw 4096 2026-01-01 00:00 Pictures
        -rw-rw---- 1 u0_a1 media_rw 10 2026-01-01 00:00 IMG_2.jpg
        -rw-rw---- 1 u0_a1 media_rw 10 2026-01-01 00:00 IMG_10.jpg
        drwxrwx--x 2 u0_a1 media_rw 4096 2026-01-01 00:00 Download
        """
        let names = PhoneFileBrowserService.parseListing(output).entries.map(\.name)
        XCTAssertEqual(names, ["Download", "Pictures", "IMG_2.jpg", "IMG_10.jpg", "zebra.txt"])
    }

    func testParsesNamesWithSpacesAndParentheses() {
        let output = "-rw-rw---- 1 u0_a123 media_rw 99 2026-06-28 18:12 boarding pass (1).pdf"
        let entries = PhoneFileBrowserService.parseListing(output).entries
        XCTAssertEqual(entries.map(\.name), ["boarding pass (1).pdf"])
    }

    func testParsesQuoteAndUnicodeNames() {
        let output = """
        -rw-rw---- 1 u0_a1 media_rw 5 2026-01-02 03:04 it's a file.txt
        -rw-rw---- 1 u0_a1 media_rw 5 2026-01-02 03:04 写真 📷.jpg
        """
        let entries = PhoneFileBrowserService.parseListing(output).entries
        XCTAssertEqual(entries.map(\.name), ["it's a file.txt", "写真 📷.jpg"])
    }

    func testParsesSymlinkNameAndTarget() {
        let output = "lrwxrwxrwx 1 root root 21 2009-01-01 00:00 sdcard -> /storage/self/primary"
        let entries = PhoneFileBrowserService.parseListing(output).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .symlink)
        XCTAssertEqual(entries[0].name, "sdcard")
        XCTAssertEqual(entries[0].symlinkTarget, "/storage/self/primary")
        XCTAssertTrue(entries[0].isNavigable)
    }

    func testTrimsSecondsFromTimestamps() {
        let output = "-rw-rw---- 1 u0_a1 media_rw 5 2026-06-28 18:12:33 notes.txt"
        let entries = PhoneFileBrowserService.parseListing(output).entries
        XCTAssertEqual(entries.first?.modifiedText, "2026-06-28 18:12")
    }

    func testParsesSELinuxMarkerAfterPermissions() {
        let output = """
        drwxrwx--x. 2 u0_a1 media_rw 4096 2026-01-01 00:00 Marked
        drwxrwx--x+ 2 u0_a1 media_rw 4096 2026-01-01 00:00 ACLs
        """
        let result = PhoneFileBrowserService.parseListing(output)
        XCTAssertEqual(result.entries.map(\.name), ["ACLs", "Marked"])
        XCTAssertEqual(result.skippedLines, 0)
    }

    func testCountsGarbageLinesAsSkippedWithoutDroppingGoodRows() {
        let output = """
        ls: /sdcard/Android/data/com.foo: Permission denied
        -rw-rw---- 1 u0_a1 media_rw 5 2026-01-01 00:00 kept.txt
        """
        let result = PhoneFileBrowserService.parseListing(output)
        XCTAssertEqual(result.entries.map(\.name), ["kept.txt"])
        XCTAssertEqual(result.skippedLines, 1)
    }

    func testParsesCRLFLineEndings() {
        let output = "drwxrwx--x 2 u0_a1 media_rw 4096 2026-01-01 00:00 Camera\r\n"
            + "-rw-rw---- 1 u0_a1 media_rw 7 2026-01-01 00:00 a.txt\r\n"
        let result = PhoneFileBrowserService.parseListing(output)
        XCTAssertEqual(result.entries.map(\.name), ["Camera", "a.txt"])
        XCTAssertEqual(result.skippedLines, 0)
    }

    func testUnknownSizeColumnYieldsNilSize() {
        let output = "-rw-rw---- 1 u0_a1 media_rw ? 2026-01-01 00:00 mystery.bin"
        let entries = PhoneFileBrowserService.parseListing(output).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].sizeBytes)
    }

    func testEmptyOutputParsesToNothing() {
        let result = PhoneFileBrowserService.parseListing("")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.skippedLines, 0)
    }

    // MARK: - shellQuoted

    func testShellQuotedWrapsPlainPaths() {
        XCTAssertEqual(
            PhoneFileBrowserService.shellQuoted("/sdcard/Download"),
            "'/sdcard/Download'"
        )
    }

    func testShellQuotedEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(
            PhoneFileBrowserService.shellQuoted("/sdcard/it's here"),
            "'/sdcard/it'\\''s here'"
        )
    }

    func testShellQuotedKeepsMetacharactersInert() {
        XCTAssertEqual(
            PhoneFileBrowserService.shellQuoted("/sdcard/a $(rm -rf) `x` ; && b"),
            "'/sdcard/a $(rm -rf) `x` ; && b'"
        )
    }

    // MARK: - Path helpers

    func testParentWalksUpAndClampsAtRoots() {
        XCTAssertEqual(PhoneFileBrowserService.parent(of: "/sdcard/Download/sub"), "/sdcard/Download")
        XCTAssertEqual(PhoneFileBrowserService.parent(of: "/sdcard/Download"), "/sdcard")
        XCTAssertNil(PhoneFileBrowserService.parent(of: "/sdcard"))
        XCTAssertEqual(
            PhoneFileBrowserService.parent(of: "/storage/ABCD-1234/x"),
            "/storage/ABCD-1234"
        )
    }

    func testIsPathAllowedRejectsOutsidersAndPrefixTraps() {
        XCTAssertTrue(PhoneFileBrowserService.isPathAllowed("/sdcard"))
        XCTAssertTrue(PhoneFileBrowserService.isPathAllowed("/sdcard/DCIM/Camera"))
        XCTAssertTrue(PhoneFileBrowserService.isPathAllowed("/storage"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/data/local/tmp"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/sdcardevil"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/"))
    }

    func testIsPathAllowedRejectsTraversalAndControlCharacters() {
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/sdcard/../data/local/tmp"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/sdcard/./Download"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/storage/emulated/0/../../data"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("/sdcard/Photo\0name.jpg"))
        XCTAssertFalse(PhoneFileBrowserService.isPathAllowed("sdcard/Download"))
    }

    func testMediaScanURIIsOneQuotedShellValue() {
        XCTAssertEqual(
            PhoneFileBrowserService.shellQuoted("file:///sdcard/DCIM/a'; touch /data/local/tmp/x; '.jpg"),
            "'file:///sdcard/DCIM/a'\\''; touch /data/local/tmp/x; '\\''.jpg'"
        )
    }

    func testJoinedHandlesTrailingSlash() {
        XCTAssertEqual(PhoneFileBrowserService.joined("/sdcard", "Download"), "/sdcard/Download")
        XCTAssertEqual(PhoneFileBrowserService.joined("/sdcard/", "Download"), "/sdcard/Download")
    }

    // MARK: - parseStorageInfo

    func testParsesDFOutputIntoBytes() {
        let output = """
        Filesystem      1K-blocks     Used Available Use% Mounted on
        /dev/fuse       115326900 26069428  89257472  23% /storage/emulated
        """
        let info = PhoneFileBrowserService.parseStorageInfo(output)
        XCTAssertEqual(info?.totalBytes, 115_326_900 * 1024)
        XCTAssertEqual(info?.freeBytes, 89_257_472 * 1024)
    }

    func testHeaderOnlyOrMalformedDFReturnsNil() {
        XCTAssertNil(PhoneFileBrowserService.parseStorageInfo(
            "Filesystem 1K-blocks Used Available Use% Mounted on"
        ))
        XCTAssertNil(PhoneFileBrowserService.parseStorageInfo("df: /nope: No such file or directory\n"))
        XCTAssertNil(PhoneFileBrowserService.parseStorageInfo(""))
    }

    // MARK: - availableDestination

    func testAvailableDestinationNumbersCollisions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBrowserParsingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = PhoneFileBrowserService.availableDestination(for: "a.txt", in: directory)
        XCTAssertEqual(first.lastPathComponent, "a.txt")
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = PhoneFileBrowserService.availableDestination(for: "a.txt", in: directory)
        XCTAssertEqual(second.lastPathComponent, "a 2.txt")
        FileManager.default.createFile(atPath: second.path, contents: Data())

        let third = PhoneFileBrowserService.availableDestination(for: "a.txt", in: directory)
        XCTAssertEqual(third.lastPathComponent, "a 3.txt")

        let noExtension = PhoneFileBrowserService.availableDestination(for: "README", in: directory)
        XCTAssertEqual(noExtension.lastPathComponent, "README")
    }

    // MARK: - relocate guards (pure paths only — no adb reaches these cases)

    func testRelocateRefusesDisallowedPathsAndNoOpsOnSamePlace() {
        let outside = PhoneFileBrowserService.relocate(
            serial: "X", remotePath: "/data/x", intoDirectory: "/sdcard", copy: false
        )
        XCTAssertFalse(outside.succeeded)

        let samePlace = PhoneFileBrowserService.relocate(
            serial: "X", remotePath: "/sdcard/Download/a.txt",
            intoDirectory: "/sdcard/Download", copy: false
        )
        XCTAssertTrue(samePlace.succeeded)
    }

    // MARK: - oneLine

    func testOneLineKeepsLastNonEmptyLine() {
        XCTAssertEqual(
            PhoneFileBrowserService.oneLine("adb: error: something\nfailed to copy\n"),
            "failed to copy"
        )
        XCTAssertEqual(PhoneFileBrowserService.oneLine(""), "")
    }
}
