import XCTest
@testable import PhoneRelay

final class PhoneWebDAVServerTests: XCTestCase {

    // MARK: - Path mapping

    func testRemotePathMapsVolumeRootToSdcard() {
        XCTAssertEqual(PhoneWebDAVSupport.remotePath(forURLPath: "/"), "/sdcard")
        XCTAssertEqual(PhoneWebDAVSupport.remotePath(forURLPath: ""), "/sdcard")
    }

    func testRemotePathMapsNestedAndDecodesPercentEscapes() {
        XCTAssertEqual(
            PhoneWebDAVSupport.remotePath(forURLPath: "/Download/report.pdf"),
            "/sdcard/Download/report.pdf"
        )
        XCTAssertEqual(
            PhoneWebDAVSupport.remotePath(forURLPath: "/Download/boarding%20pass.pdf"),
            "/sdcard/Download/boarding pass.pdf"
        )
        XCTAssertEqual(
            PhoneWebDAVSupport.remotePath(forURLPath: "/DCIM/Camera/"),
            "/sdcard/DCIM/Camera"
        )
    }

    func testRemotePathRejectsTraversalAndStripsQueries() {
        XCTAssertNil(PhoneWebDAVSupport.remotePath(forURLPath: "/../etc/passwd"))
        XCTAssertNil(PhoneWebDAVSupport.remotePath(forURLPath: "/Download/../../data"))
        XCTAssertNil(PhoneWebDAVSupport.remotePath(forURLPath: "/%2e%2e/data"))
        XCTAssertNil(PhoneWebDAVSupport.remotePath(forURLPath: "Download"))
        XCTAssertEqual(
            PhoneWebDAVSupport.remotePath(forURLPath: "/Download?x=1"),
            "/sdcard/Download"
        )
    }

    // MARK: - Hrefs and XML

    func testEncodedHrefEscapesSegmentsAndMarksCollections() {
        XCTAssertEqual(
            PhoneWebDAVSupport.encodedHref(urlPath: "/Download/boarding pass.pdf", isCollection: false),
            "/Download/boarding%20pass.pdf"
        )
        XCTAssertEqual(
            PhoneWebDAVSupport.encodedHref(urlPath: "/DCIM/Camera", isCollection: true),
            "/DCIM/Camera/"
        )
        XCTAssertEqual(PhoneWebDAVSupport.encodedHref(urlPath: "/", isCollection: true), "/")
    }

    func testXMLEscaping() {
        XCTAssertEqual(
            PhoneWebDAVSupport.xmlEscaped(#"a<b>&"c""#),
            "a&lt;b&gt;&amp;&quot;c&quot;"
        )
    }

    func testPropfindResponseXMLForFileIncludesLengthAndType() {
        let xml = PhoneWebDAVSupport.propfindResponseXML(
            href: "/Download/a.pdf",
            displayName: "a.pdf",
            isCollection: false,
            sizeBytes: 42,
            modifiedText: "2026-07-02 10:22"
        )
        XCTAssertTrue(xml.contains("<D:getcontentlength>42</D:getcontentlength>"))
        XCTAssertTrue(xml.contains("<D:getcontenttype>application/pdf</D:getcontenttype>"))
        XCTAssertTrue(xml.contains("<D:getlastmodified>"))
        XCTAssertTrue(xml.contains("GMT</D:getlastmodified>"))
        XCTAssertFalse(xml.contains("<D:collection/>"))
    }

    func testPropfindResponseXMLForCollectionIncludesQuota() {
        let xml = PhoneWebDAVSupport.propfindResponseXML(
            href: "/",
            displayName: "Phone",
            isCollection: true,
            sizeBytes: nil,
            modifiedText: nil,
            quotaAvailable: 1000,
            quotaUsed: 500
        )
        XCTAssertTrue(xml.contains("<D:collection/>"))
        XCTAssertTrue(xml.contains("<D:quota-available-bytes>1000</D:quota-available-bytes>"))
        XCTAssertTrue(xml.contains("<D:quota-used-bytes>500</D:quota-used-bytes>"))
    }

    // MARK: - Headers

    func testDestinationHeaderParsing() {
        XCTAssertEqual(
            PhoneWebDAVSupport.destinationURLPath(
                fromHeader: "http://127.0.0.1:8080/Download/new%20name.txt"
            ),
            "/Download/new%20name.txt"
        )
        XCTAssertEqual(
            PhoneWebDAVSupport.destinationURLPath(fromHeader: "/Download/x.txt"),
            "/Download/x.txt"
        )
        XCTAssertNil(PhoneWebDAVSupport.destinationURLPath(fromHeader: "not a url"))
    }

    func testFinderMetadataClassification() {
        XCTAssertTrue(PhoneWebDAVSupport.isFinderMetadataName(".DS_Store"))
        XCTAssertTrue(PhoneWebDAVSupport.isFinderMetadataName("._photo.jpg"))
        XCTAssertFalse(PhoneWebDAVSupport.isFinderMetadataName(".hidden"))
        XCTAssertFalse(PhoneWebDAVSupport.isFinderMetadataName("photo.jpg"))
        XCTAssertTrue(PhoneWebDAVSupport.isFinderMetadataPath("/DCIM/._IMG.jpg"))
        XCTAssertFalse(PhoneWebDAVSupport.isFinderMetadataPath("/DCIM/IMG.jpg"))
    }

    // MARK: - HTTP request parsing

    func testParseRequestReadsHeadersAndBody() {
        var data = Data(
            "PUT /Download/a.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello".utf8
        )
        let request = PhoneWebDAVServer.parseRequest(from: &data)
        XCTAssertEqual(request?.method, "PUT")
        XCTAssertEqual(request?.urlPath, "/Download/a.txt")
        XCTAssertEqual(request?.headers["content-length"], "5")
        XCTAssertEqual(request.map { String(data: $0.body, encoding: .utf8) }, "hello")
        XCTAssertTrue(data.isEmpty)
    }

    func testParseRequestWaitsForFullBody() {
        var data = Data("PUT /a HTTP/1.1\r\nContent-Length: 10\r\n\r\nhal".utf8)
        XCTAssertNil(PhoneWebDAVServer.parseRequest(from: &data))
        XCTAssertFalse(data.isEmpty)
        data.append(Data("f-body!".utf8))
        let request = PhoneWebDAVServer.parseRequest(from: &data)
        XCTAssertEqual(request.map { String(data: $0.body, encoding: .utf8) }, "half-body!")
    }

    func testParseRequestHandlesPipelinedRequests() {
        var data = Data(
            "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8
        )
        XCTAssertEqual(PhoneWebDAVServer.parseRequest(from: &data)?.urlPath, "/a")
        XCTAssertEqual(PhoneWebDAVServer.parseRequest(from: &data)?.urlPath, "/b")
        XCTAssertNil(PhoneWebDAVServer.parseRequest(from: &data))
    }

    // MARK: - Content types

    func testContentTypeMapping() {
        XCTAssertEqual(PhoneWebDAVSupport.contentType(forName: "a.JPG"), "image/jpeg")
        XCTAssertEqual(PhoneWebDAVSupport.contentType(forName: "b.pdf"), "application/pdf")
        XCTAssertEqual(PhoneWebDAVSupport.contentType(forName: "c.unknown"), "application/octet-stream")
    }
}
