import Foundation
import XCTest
@testable import GPTSwitch

final class HTTPTypesTests: XCTestCase {
    func testParserWaitsForCompleteBody() throws {
        let header = "POST /api/images/generations HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\n"
        XCTAssertEqual(try HTTPRequestParser.expectedRequestLength(in: Data(header.utf8)), header.utf8.count + 13)
        XCTAssertNil(try HTTPRequestParser.expectedRequestLength(in: Data("POST / HTTP/1.1\r\n".utf8)))
    }

    func testParserReadsNormalizedHeadersAndBody() throws {
        let body = "{\"prompt\":\"x\"}"
        let raw = "POST /api/images/generations?x=1 HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))

        XCTAssertEqual(request.path, "/api/images/generations")
        XCTAssertEqual(request.header("Authorization"), "Bearer abc")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }
}
