import Foundation
import Network

struct IncomingHTTPRequest: Sendable {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let body: Data

    var path: String {
        URLComponents(string: target)?.path ?? target
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum HTTPRequestParserError: LocalizedError {
    case malformedRequest
    case invalidContentLength
    case unsupportedChunkedRequest
    case requestTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedRequest: "无效的本地 HTTP 请求"
        case .invalidContentLength: "无效的 Content-Length"
        case .unsupportedChunkedRequest: "本地请求暂不支持 chunked 正文"
        case .requestTooLarge: "请求正文超过 100 MiB 限制"
        }
    }
}

enum HTTPRequestParser {
    static let maximumRequestBytes = 100 * 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func expectedRequestLength(in data: Data) throws -> Int? {
        guard let range = data.range(of: headerTerminator) else {
            if data.count > 64 * 1024 {
                throw HTTPRequestParserError.malformedRequest
            }
            return nil
        }
        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPRequestParserError.malformedRequest
        }
        let headers = try parseHeaderLines(headerText).headers
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            throw HTTPRequestParserError.unsupportedChunkedRequest
        }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                throw HTTPRequestParserError.invalidContentLength
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumRequestBytes else {
            throw HTTPRequestParserError.requestTooLarge
        }
        return range.upperBound + contentLength
    }

    static func parse(_ data: Data) throws -> IncomingHTTPRequest {
        guard let range = data.range(of: headerTerminator) else {
            throw HTTPRequestParserError.malformedRequest
        }
        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPRequestParserError.malformedRequest
        }
        let parsed = try parseHeaderLines(headerText)
        let body = Data(data[range.upperBound...])
        return IncomingHTTPRequest(
            method: parsed.method,
            target: parsed.target,
            version: parsed.version,
            headers: parsed.headers,
            body: body
        )
    }

    private static func parseHeaderLines(
        _ text: String
    ) throws -> (method: String, target: String, version: String, headers: [String: String]) {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPRequestParserError.malformedRequest
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            throw HTTPRequestParserError.malformedRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPRequestParserError.malformedRequest
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }
        return (parts[0], parts[1], parts[2], headers)
    }
}

enum HTTPResponseWriter {
    static func sendJSON(
        status: Int,
        object: Any,
        to connection: NWConnection,
        completion: (() -> Void)? = nil
    ) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(status: status, contentType: "application/json; charset=utf-8", body: body, to: connection, completion: completion)
    }

    static func send(
        status: Int,
        contentType: String,
        body: Data,
        to connection: NWConnection,
        completion: (() -> Void)? = nil
    ) {
        var response = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    static func error(status: Int, message: String, to connection: NWConnection) {
        sendJSON(
            status: status,
            object: ["error": ["message": message, "type": "codex_imagegen_proxy_error"]],
            to: connection
        )
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }
}
