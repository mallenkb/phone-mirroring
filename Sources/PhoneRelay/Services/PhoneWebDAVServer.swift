import Foundation
import Network

/// Pure helpers for the WebDAV bridge, split out so they're unit-testable
/// without a socket or a phone.
enum PhoneWebDAVSupport {

    /// Finder metadata files never reach the phone: AppleDouble (`._*`) and
    /// `.DS_Store` writes are kept in a session-scoped in-memory store so
    /// Finder's round-trips (including custom volume icons) still work.
    nonisolated static func isFinderMetadataName(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    nonisolated static func isFinderMetadataPath(_ urlPath: String) -> Bool {
        isFinderMetadataName((urlPath as NSString).lastPathComponent)
    }

    /// Maps a percent-encoded request path onto the phone's shared storage.
    /// Returns nil for escapes (`..`), foreign roots, or undecodable paths.
    nonisolated static func remotePath(forURLPath urlPath: String) -> String? {
        let normalized = urlPath.isEmpty ? "/" : urlPath
        let raw = normalized.split(separator: "?", maxSplits: 1)[0]
        guard let decoded = String(raw).removingPercentEncoding else { return nil }
        guard decoded.hasPrefix("/") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains(".") else { return nil }
        let remote = components.isEmpty
            ? PhoneFileBrowserService.defaultRoot
            : PhoneFileBrowserService.defaultRoot + "/" + components.joined(separator: "/")
        guard PhoneFileBrowserService.isPathAllowed(remote) else { return nil }
        return remote
    }

    /// Href for a child entry inside a collection href. Every path segment is
    /// individually percent-encoded; collections get a trailing slash.
    nonisolated static func encodedHref(urlPath: String, isCollection: Bool) -> String {
        let segments = urlPath.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }
        let joined = "/" + segments.joined(separator: "/")
        if isCollection {
            return joined == "/" ? "/" : joined + "/"
        }
        return joined
    }

    nonisolated static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Destination header → still-percent-encoded URL path (used by
    /// MOVE/COPY; the caller decodes exactly once via remotePath). Accepts
    /// absolute http(s) URLs and bare paths; modern Foundation's lenient URL
    /// parser would otherwise accept plain garbage, so the scheme is checked.
    nonisolated static func destinationURLPath(fromHeader value: String) -> String? {
        if value.hasPrefix("/") { return value }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? nil : path
    }

    /// "2026-07-02 10:22" (phone-local, assumed ≈ Mac-local) → RFC 1123 for
    /// getlastmodified. Nil when the text doesn't parse.
    nonisolated static func rfc1123Date(fromListingText text: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        parser.timeZone = .current
        guard let date = parser.date(from: text) else { return nil }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        output.timeZone = TimeZone(identifier: "GMT")
        return output.string(from: date)
    }

    nonisolated static func contentType(forName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "xml": return "application/xml"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// One <D:response> block for a PROPFIND multistatus body.
    nonisolated static func propfindResponseXML(
        href: String,
        displayName: String,
        isCollection: Bool,
        sizeBytes: Int64?,
        modifiedText: String?,
        quotaAvailable: Int64? = nil,
        quotaUsed: Int64? = nil
    ) -> String {
        var props = ""
        props += "<D:displayname>\(xmlEscaped(displayName))</D:displayname>"
        if isCollection {
            props += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            props += "<D:resourcetype/>"
            props += "<D:getcontentlength>\(sizeBytes ?? 0)</D:getcontentlength>"
            props += "<D:getcontenttype>\(contentType(forName: displayName))</D:getcontenttype>"
        }
        if let modifiedText, let rfcDate = rfc1123Date(fromListingText: modifiedText) {
            props += "<D:getlastmodified>\(rfcDate)</D:getlastmodified>"
        }
        if let quotaAvailable {
            props += "<D:quota-available-bytes>\(quotaAvailable)</D:quota-available-bytes>"
        }
        if let quotaUsed {
            props += "<D:quota-used-bytes>\(quotaUsed)</D:quota-used-bytes>"
        }
        return "<D:response><D:href>\(xmlEscaped(href))</D:href>"
            + "<D:propstat><D:prop>\(props)</D:prop>"
            + "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }
}

/// Minimal WebDAV class-2 server on 127.0.0.1 bridging Finder to the phone
/// via adb. One server per connected device; Finder mounts it through
/// mount_webdav. LOCK/UNLOCK are honored with fake tokens (mount_webdav
/// refuses read-write mounts without class 2), and Finder metadata files
/// live only in memory.
final class PhoneWebDAVServer: @unchecked Sendable {

    private let serial: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "PhoneWebDAVServer", attributes: .concurrent)
    private let stateLock = NSLock()
    /// In-memory Finder metadata (._* and .DS_Store), keyed by URL path.
    private var metadataStore: [String: Data] = [:]
    private static let metadataEntryLimit = 512
    private static let metadataSizeLimit = 4 * 1024 * 1024
    /// Short-lived directory listing cache; Finder issues PROPFIND storms.
    private var listingCache: [String: (at: Date, listing: [PhoneFileEntry])] = [:]
    private static let listingCacheTTL: TimeInterval = 2

    init(serial: String) {
        self.serial = serial
    }

    /// Starts listening; returns the base URL to mount.
    func start() throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port, port.rawValue > 0 else {
            listener.cancel()
            throw NSError(domain: "PhoneWebDAVServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The local file server couldn't start."
            ])
        }
        self.listener = listener
        return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection loop

    struct HTTPRequest {
        var method: String
        var urlPath: String
        var headers: [String: String]
        var body: Data
    }

    private final class ConnectionBuffer {
        var data = Data()
    }

    private func serve(_ connection: NWConnection) {
        let buffer = ConnectionBuffer()
        connection.start(queue: queue)
        receiveNext(connection, buffer: buffer)
    }

    private func receiveNext(_ connection: NWConnection, buffer: ConnectionBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let data { buffer.data.append(data) }
            if error != nil || (isComplete && buffer.data.isEmpty) {
                connection.cancel()
                return
            }
            self.drainRequests(connection, buffer: buffer, closeAfter: isComplete)
        }
    }

    /// Parses every complete request in the buffer (requests can be
    /// pipelined), responds, then re-arms the receive.
    private func drainRequests(_ connection: NWConnection, buffer: ConnectionBuffer, closeAfter: Bool) {
        while let request = Self.parseRequest(from: &buffer.data) {
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            handle(request, on: connection)
            if !keepAlive {
                connection.cancel()
                return
            }
        }
        if closeAfter {
            connection.cancel()
        } else {
            receiveNext(connection, buffer: buffer)
        }
    }

    /// Consumes one complete request from the front of `data`, or returns nil
    /// when more bytes are needed.
    nonisolated static func parseRequest(from data: inout Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else {
            data.removeAll()
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            data.removeAll()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= bodyLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: bodyLength)
        let body = Data(data[bodyStart..<bodyEnd])
        data.removeSubrange(data.startIndex..<bodyEnd)
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            urlPath: String(requestLine[1]),
            headers: headers,
            body: body
        )
    }

    // MARK: - Responses

    private func send(
        _ connection: NWConnection,
        status: String,
        headers extra: [String: String] = [:],
        body: Data = Data(),
        omitBody: Bool = false
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        var headers = extra
        headers["Content-Length"] = "\(body.count)"
        headers["Server"] = "PhoneRelay-WebDAV"
        headers["Date"] = Self.httpDate()
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        if !omitBody { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    nonisolated private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.string(from: Date())
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard let remotePath = PhoneWebDAVSupport.remotePath(forURLPath: request.urlPath) else {
            send(connection, status: "403 Forbidden")
            return
        }
        let isMetadata = PhoneWebDAVSupport.isFinderMetadataPath(request.urlPath)

        switch request.method {
        case "OPTIONS":
            send(connection, status: "200 OK", headers: [
                "DAV": "1, 2",
                "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, COPY, LOCK, UNLOCK"
            ])
        case "PROPFIND":
            if isMetadata {
                handleMetadataPropfind(request, remotePath: remotePath, on: connection)
            } else {
                handlePropfind(request, remotePath: remotePath, on: connection)
            }
        case "GET", "HEAD":
            if isMetadata {
                handleMetadataGet(request, on: connection)
            } else {
                handleGet(request, remotePath: remotePath, on: connection)
            }
        case "PUT":
            if isMetadata {
                storeMetadata(request.urlPath, data: request.body)
                send(connection, status: "201 Created")
            } else {
                handlePut(request, remotePath: remotePath, on: connection)
            }
        case "DELETE":
            if isMetadata {
                storeMetadata(request.urlPath, data: nil)
                send(connection, status: "204 No Content")
            } else {
                handleDelete(remotePath: remotePath, on: connection)
            }
        case "MKCOL":
            handleMkcol(remotePath: remotePath, on: connection)
        case "MOVE", "COPY":
            handleMoveCopy(request, remotePath: remotePath, isMetadata: isMetadata, on: connection)
        case "LOCK":
            let token = "opaquelocktoken:\(UUID().uuidString)"
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>
            <D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>
            <D:depth>0</D:depth><D:timeout>Second-600</D:timeout>
            <D:locktoken><D:href>\(token)</D:href></D:locktoken>
            </D:activelock></D:lockdiscovery></D:prop>
            """
            send(connection, status: "200 OK", headers: [
                "Lock-Token": "<\(token)>",
                "Content-Type": "application/xml; charset=utf-8"
            ], body: Data(body.utf8))
        case "UNLOCK":
            send(connection, status: "204 No Content")
        case "PROPPATCH":
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:"><D:response>
            <D:href>\(PhoneWebDAVSupport.xmlEscaped(request.urlPath))</D:href>
            <D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            </D:response></D:multistatus>
            """
            send(connection, status: "207 Multi-Status", headers: [
                "Content-Type": "application/xml; charset=utf-8"
            ], body: Data(body.utf8))
        default:
            send(connection, status: "405 Method Not Allowed")
        }
    }

    // MARK: - Finder metadata (in-memory)

    private func storeMetadata(_ urlPath: String, data: Data?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let data else {
            metadataStore[urlPath] = nil
            return
        }
        guard data.count <= Self.metadataSizeLimit else { return }
        if metadataStore.count >= Self.metadataEntryLimit, metadataStore[urlPath] == nil {
            metadataStore.removeValue(forKey: metadataStore.keys.first ?? "")
        }
        metadataStore[urlPath] = data
    }

    private func metadata(_ urlPath: String) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return metadataStore[urlPath]
    }

    private func handleMetadataGet(_ request: HTTPRequest, on connection: NWConnection) {
        guard let data = metadata(request.urlPath) else {
            send(connection, status: "404 Not Found")
            return
        }
        send(
            connection,
            status: "200 OK",
            headers: ["Content-Type": "application/octet-stream"],
            body: data,
            omitBody: request.method == "HEAD"
        )
    }

    private func handleMetadataPropfind(
        _ request: HTTPRequest, remotePath: String, on connection: NWConnection
    ) {
        guard let data = metadata(request.urlPath) else {
            send(connection, status: "404 Not Found")
            return
        }
        let name = (remotePath as NSString).lastPathComponent
        let response = PhoneWebDAVSupport.propfindResponseXML(
            href: PhoneWebDAVSupport.encodedHref(urlPath: request.urlPath, isCollection: false),
            displayName: name,
            isCollection: false,
            sizeBytes: Int64(data.count),
            modifiedText: nil
        )
        sendMultistatus(connection, responses: [response])
    }

    private func sendMultistatus(_ connection: NWConnection, responses: [String]) {
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<D:multistatus xmlns:D=\"DAV:\">"
            + responses.joined()
            + "</D:multistatus>"
        send(connection, status: "207 Multi-Status", headers: [
            "Content-Type": "application/xml; charset=utf-8"
        ], body: Data(body.utf8))
    }

    // MARK: - PROPFIND

    private func cachedListing(_ remotePath: String) -> [PhoneFileEntry]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let cached = listingCache[remotePath],
              Date().timeIntervalSince(cached.at) < Self.listingCacheTTL
        else { return nil }
        return cached.listing
    }

    private func cacheListing(_ remotePath: String, _ listing: [PhoneFileEntry]) {
        stateLock.lock()
        listingCache[remotePath] = (Date(), listing)
        stateLock.unlock()
    }

    func invalidateListingCache() {
        stateLock.lock()
        listingCache.removeAll()
        stateLock.unlock()
    }

    private func listDirectory(_ remotePath: String) -> [PhoneFileEntry]? {
        if let cached = cachedListing(remotePath) { return cached }
        guard case .success(let result) = PhoneFileBrowserService.listDirectory(
            serial: serial, path: remotePath
        ) else { return nil }
        cacheListing(remotePath, result.entries)
        return result.entries
    }

    private func handlePropfind(
        _ request: HTTPRequest, remotePath: String, on connection: NWConnection
    ) {
        let depth = request.headers["depth"] ?? "1"
        let isRoot = remotePath == PhoneFileBrowserService.defaultRoot
        guard let selfEntry = isRoot
            ? PhoneFileEntry(
                name: "Phone", kind: .directory, sizeBytes: nil,
                modifiedText: "", symlinkTarget: nil
            )
            : PhoneFileBrowserService.statPath(serial: serial, path: remotePath)
        else {
            send(connection, status: "404 Not Found")
            return
        }

        let basePath = request.urlPath.hasSuffix("/") || request.urlPath.isEmpty
            ? request.urlPath
            : request.urlPath + (selfEntry.isNavigable ? "/" : "")
        var responses: [String] = []

        var quotaAvailable: Int64?
        var quotaUsed: Int64?
        if isRoot, let storage = PhoneFileBrowserService.storageInfo(
            serial: serial, path: remotePath
        ) {
            quotaAvailable = storage.freeBytes
            quotaUsed = storage.totalBytes - storage.freeBytes
        }
        responses.append(PhoneWebDAVSupport.propfindResponseXML(
            href: PhoneWebDAVSupport.encodedHref(
                urlPath: request.urlPath, isCollection: selfEntry.isNavigable
            ),
            displayName: selfEntry.name,
            isCollection: selfEntry.isNavigable,
            sizeBytes: selfEntry.sizeBytes,
            modifiedText: selfEntry.modifiedText.isEmpty ? nil : selfEntry.modifiedText,
            quotaAvailable: quotaAvailable,
            quotaUsed: quotaUsed
        ))

        if depth != "0", selfEntry.isNavigable {
            guard let children = listDirectory(remotePath) else {
                send(connection, status: "404 Not Found")
                return
            }
            for child in children where !PhoneWebDAVSupport.isFinderMetadataName(child.name) {
                let childURLPath = basePath.hasSuffix("/")
                    ? basePath + child.name
                    : basePath + "/" + child.name
                responses.append(PhoneWebDAVSupport.propfindResponseXML(
                    href: PhoneWebDAVSupport.encodedHref(
                        urlPath: childURLPath, isCollection: child.isNavigable
                    ),
                    displayName: child.name,
                    isCollection: child.isNavigable,
                    sizeBytes: child.sizeBytes,
                    modifiedText: child.modifiedText
                ))
            }
        }
        sendMultistatus(connection, responses: responses)
    }

    // MARK: - File transfer

    private func handleGet(
        _ request: HTTPRequest, remotePath: String, on connection: NWConnection
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelay WebDAV", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            send(connection, status: "500 Internal Server Error")
            return
        }
        guard case .success(let local) = PhoneFileBrowserService.pull(
            serial: serial, remotePath: remotePath, localDirectory: scratch
        ), let data = try? Data(contentsOf: local) else {
            send(connection, status: "404 Not Found")
            return
        }
        let name = (remotePath as NSString).lastPathComponent
        send(
            connection,
            status: "200 OK",
            headers: ["Content-Type": PhoneWebDAVSupport.contentType(forName: name)],
            body: data,
            omitBody: request.method == "HEAD"
        )
    }

    private func handlePut(
        _ request: HTTPRequest, remotePath: String, on connection: NWConnection
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelay WebDAV", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = (remotePath as NSString).lastPathComponent
        let local = scratch.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try request.body.write(to: local)
        } catch {
            send(connection, status: "500 Internal Server Error")
            return
        }
        let parent = (remotePath as NSString).deletingLastPathComponent
        let outcome = PhoneFileBrowserService.push(
            serial: serial, localPath: local.path, remoteDirectory: parent
        )
        invalidateListingCache()
        if outcome.succeeded {
            PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: remotePath)
            send(connection, status: "201 Created")
        } else {
            send(connection, status: "507 Insufficient Storage")
        }
    }

    private func handleDelete(remotePath: String, on connection: NWConnection) {
        let entry = PhoneFileBrowserService.statPath(serial: serial, path: remotePath)
        let outcome = PhoneFileBrowserService.delete(
            serial: serial, remotePath: remotePath, isDirectory: entry?.isNavigable ?? false
        )
        invalidateListingCache()
        if outcome.succeeded {
            PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: remotePath)
        }
        send(connection, status: outcome.succeeded ? "204 No Content" : "403 Forbidden")
    }

    private func handleMkcol(remotePath: String, on connection: NWConnection) {
        let parent = (remotePath as NSString).deletingLastPathComponent
        let name = (remotePath as NSString).lastPathComponent
        let outcome = PhoneFileBrowserService.makeDirectory(
            serial: serial, parentPath: parent, name: name
        )
        invalidateListingCache()
        send(connection, status: outcome.succeeded ? "201 Created" : "409 Conflict")
    }

    private func handleMoveCopy(
        _ request: HTTPRequest, remotePath: String, isMetadata: Bool, on connection: NWConnection
    ) {
        guard let destinationHeader = request.headers["destination"],
              let destinationURLPath = PhoneWebDAVSupport.destinationURLPath(
                fromHeader: destinationHeader
              ),
              let destinationRemote = PhoneWebDAVSupport.remotePath(forURLPath: destinationURLPath)
        else {
            send(connection, status: "400 Bad Request")
            return
        }
        if isMetadata || PhoneWebDAVSupport.isFinderMetadataPath(destinationURLPath) {
            // Metadata moves shuffle the in-memory store instead of the phone.
            let data = metadata(request.urlPath)
            if request.method == "MOVE" { storeMetadata(request.urlPath, data: nil) }
            if let data { storeMetadata(destinationURLPath, data: data) }
            send(connection, status: "201 Created")
            return
        }
        let command = request.method == "MOVE" ? ["mv"] : ["cp", "-r"]
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell"] + command + [
                PhoneFileBrowserService.shellQuoted(remotePath),
                PhoneFileBrowserService.shellQuoted(destinationRemote)
            ],
            timeout: 300
        )
        invalidateListingCache()
        if result.succeeded {
            PhoneFileBrowserService.requestMediaScan(serial: serial, remotePath: destinationRemote)
        }
        send(connection, status: result.succeeded ? "201 Created" : "403 Forbidden")
    }
}
