import XCTest
@testable import Vesper

final class ContractTests: XCTestCase {
    func testLosslessUnknownFieldsSurviveEditing() throws {
        let data = Data(#"{"id":"n1","text":"旧便笺","futureMetadata":{"source":"agent","pinned":true},"values":[null,1,false]}"#.utf8)
        var value = try JSONDecoder().decode(JSONValue.self, from: data)
        value["text"] = .string("新便笺")
        let restored = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored["futureMetadata"]["pinned"], .bool(true))
        XCTAssertEqual(restored["values"], .array([.null, .number(1), .bool(false)]))
        XCTAssertEqual(restored["text"].string, "新便笺")
    }
    func testHistoryPrefixAndQueryArePreserved() throws {
        let url = try APIClient.validatedURL("https://example.com/history", path: "/conversations?q=hello%20world")
        XCTAssertEqual(url.absoluteString, "https://example.com/history/conversations?q=hello%20world")
    }
    func testCredentialsCannotUseInsecureOrEmbeddedAuthEndpoints() {
        XCTAssertThrowsError(try APIClient.validatedURL("http://example.com", path: "/api/state"))
        XCTAssertThrowsError(try APIClient.validatedURL("https://user:secret@example.com", path: "/api/state"))
        XCTAssertThrowsError(try APIClient.validatedURL("file:///tmp/foo", path: "/api/state"))
    }
}
