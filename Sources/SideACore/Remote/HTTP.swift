import Foundation

/// Header names compare without case; the first of a repeated name wins, and the parser refuses the repeats that matter.
public struct HTTPHeaders: Sendable, Equatable {
    public private(set) var fields: [(name: String, value: String)]

    public init(_ fields: [(String, String)] = []) { self.fields = fields.map { (name: $0.0, value: $0.1) } }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Comma-separated tokens, lowercased: `Connection: keep-alive, Upgrade`.
    public func tokens(_ name: String) -> Set<String> {
        Set(all(name).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    public mutating func add(_ name: String, _ value: String) { fields.append((name: name, value: value)) }

    public static func == (a: HTTPHeaders, b: HTTPHeaders) -> Bool {
        a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let target: String
    /// Percent-decoded path segments: `/v1/sessions/a%20b` is `["v1", "sessions", "a b"]`.
    public let path: [String]
    public let query: [String: String]
    public let headers: HTTPHeaders
    public let body: Data

    public var keepAlive: Bool { !headers.tokens("Connection").contains("close") }
    public var wantsUpgrade: Bool { headers.tokens("Connection").contains("upgrade") && headers["Upgrade"]?.lowercased() == "websocket" }

    public init(method: String, target: String, path: [String], query: [String: String], headers: HTTPHeaders, body: Data) {
        self.method = method; self.target = target; self.path = path; self.query = query; self.headers = headers; self.body = body
    }
}

/// A request the parser refuses. The connection always closes after one: what follows can't be framed.
public struct HTTPError: Error, Sendable, Equatable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

/// A push parser for HTTP/1.1 requests: bodies by Content-Length only, no chunked encoding, no line folding.
public struct HTTPParser: Sendable {
    struct Limits: Sendable {
        let requestLine = 8 << 10
        let head = 16 << 10
        let headers = 64
        let body = 1 << 20
    }

    public static let methods: Set<String> = ["GET", "POST", "DELETE"]

    private let limits = Limits()
    /// The body a request may have, decided from its head before a byte of the body is kept: a larger one for some
    /// routes, such as uploads, a smaller one for a caller who isn't signed in. Nil keeps `limits.body`.
    private let bodyLimit: @Sendable (_ head: HTTPRequest) -> Int?
    private var buffer = Data()
    private var head: (request: HTTPRequest, length: Int)?
    private var failed = false

    public init(bodyLimit: @escaping @Sendable (HTTPRequest) -> Int? = { _ in nil }) {
        self.bodyLimit = bodyLimit
    }

    /// Every request now complete, in order. After an error nothing more is parsed.
    public mutating func feed(_ bytes: Data) -> [Result<HTTPRequest, HTTPError>] {
        guard !failed else { return [] }
        buffer.append(bytes)
        var out: [Result<HTTPRequest, HTTPError>] = []
        while true {
            if head == nil {
                switch parseHead() {
                case .none: return out
                case .failure(let error): failed = true; buffer = Data(); out.append(.failure(error)); return out
                case .success(let parsed): head = parsed
                }
            }
            guard let (request, length) = head, buffer.count >= length else { return out }
            let body = Data(buffer.prefix(length))
            buffer = Data(buffer.dropFirst(length))
            head = nil
            out.append(.success(HTTPRequest(method: request.method, target: request.target, path: request.path, query: request.query,
                                            headers: request.headers, body: body)))
            // An upgraded connection's next bytes are WebSocket frames, not another request.
            if request.wantsUpgrade { return out }
        }
    }

    /// Bytes after the last request handed out, for a connection that switches protocols.
    public mutating func takeRemainder() -> Data {
        defer { buffer = Data() }
        return buffer
    }

    private mutating func parseHead() -> Result<(request: HTTPRequest, length: Int), HTTPError>? {
        let end = buffer.firstRange(of: Data("\r\n\r\n".utf8))
        if end == nil {
            if let line = buffer.firstRange(of: Data("\r\n".utf8)) {
                if line.lowerBound - buffer.startIndex > limits.requestLine { return .failure(HTTPError(414, "The request line is too long.")) }
            } else if buffer.count > limits.requestLine {
                return .failure(HTTPError(414, "The request line is too long."))
            }
            return buffer.count > limits.head ? .failure(HTTPError(431, "The request headers are too large.")) : nil
        }
        let headBytes = buffer[buffer.startIndex..<end!.lowerBound]
        guard headBytes.count + 4 <= limits.head else { return .failure(HTTPError(431, "The request headers are too large.")) }
        guard !headBytes.contains(where: { $0 >= 0x80 || $0 == 0 }), let text = String(data: headBytes, encoding: .ascii) else {
            return .failure(HTTPError(400, "The request headers aren't ASCII."))
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        guard requestLine.utf8.count <= limits.requestLine else { return .failure(HTTPError(414, "The request line is too long.")) }
        // A bare CR or LF inside the head means a client and a proxy could disagree on where lines end.
        guard !lines.contains(where: { $0.contains("\r") || $0.contains("\n") }), !requestLine.contains("\n"), !requestLine.contains("\r") else {
            return .failure(HTTPError(400, "The request has a bare line break."))
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .failure(HTTPError(400, "The request line is malformed.")) }
        let method = String(parts[0]), target = String(parts[1])
        guard lines.count <= limits.headers else { return .failure(HTTPError(431, "The request has too many headers.")) }
        var headers = HTTPHeaders()
        for line in lines {
            guard let first = line.first, first != " ", first != "\t" else { return .failure(HTTPError(400, "Folded headers aren't accepted.")) }
            guard let colon = line.firstIndex(of: ":") else { return .failure(HTTPError(400, "A header has no colon.")) }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.allSatisfy(Self.isToken) else { return .failure(HTTPError(400, "A header name is malformed.")) }
            headers.add(name, line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
        }
        guard Self.methods.contains(method) else { return .failure(HTTPError(405, "Only GET, POST and DELETE are served.")) }
        guard headers["Transfer-Encoding"] == nil else { return .failure(HTTPError(411, "Send a Content-Length instead of Transfer-Encoding.")) }
        guard headers["Expect"] == nil else { return .failure(HTTPError(417, "Expect isn't supported; send the body with the request.")) }
        let lengths = headers.all("Content-Length")
        guard lengths.count <= 1 else { return .failure(HTTPError(400, "The request has more than one Content-Length.")) }
        var length = 0
        if let value = lengths.first {
            guard !value.isEmpty, value.utf8.count <= 12, value.allSatisfy(\.isASCIIDigit), let parsed = Int(value) else {
                return .failure(HTTPError(400, "The Content-Length is malformed."))
            }
            length = parsed
        }
        guard let (path, query) = Self.split(target) else { return .failure(HTTPError(400, "The path is malformed.")) }
        let head = HTTPRequest(method: method, target: target, path: path, query: query, headers: headers, body: Data())
        guard length <= (bodyLimit(head) ?? limits.body) else { return .failure(HTTPError(413, "The request body is too large.")) }
        buffer = Data(buffer[end!.upperBound...])
        return .success((head, length))
    }

    /// Origin-form targets only. A decoded segment of `..` or one holding a `/` is refused, so routes never see either.
    static func split(_ target: String) -> (path: [String], query: [String: String])? {
        guard target.hasPrefix("/"), !target.contains("#") else { return nil }
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var path: [String] = []
        for raw in pieces[0].split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = String(raw).removingPercentEncoding, segment != "..", segment != ".", !segment.contains("/") else { return nil }
            path.append(segment)
        }
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                      let value = (kv.count > 1 ? String(kv[1]) : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
                if query[key] == nil { query[key] = value }
            }
        }
        return (path, query)
    }

    private static func isToken(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue, ascii > 32, ascii < 127 else { return false }
        return !"()<>@,;:\\\"/[]?={}".contains(c)
    }
}

private extension Character {
    var isASCIIDigit: Bool { asciiValue.map { $0 >= 48 && $0 <= 57 } ?? false }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: Int, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: HTTPHeaders([("Content-Type", "application/json")]), body: body)
    }

    /// Always with a Content-Length, written whole; never chunked.
    public func encoded(close: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for field in headers.fields where !["content-length", "connection"].contains(field.name.lowercased()) {
            text += "\(field.name): \(field.value)\r\n"
        }
        // A client must see `Connection: Upgrade` on a 101 (RFC 6455 4.1); URLSession refuses the socket without it.
        if status == 101 { text += "Connection: Upgrade\r\n" } else { text += "Content-Length: \(body.count)\r\n" }
        if close { text += "Connection: close\r\n" }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 417: "Expectation Failed"
        case 421: "Misdirected Request"
        case 422: "Unprocessable Content"
        case 426: "Upgrade Required"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
