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
    func testActivityDoesNotBecomeAnAssistantReplyOrSwallowUserText() throws {
        let data = Data(#"[{"id":"1","role":"user","content":"read_vesper_state"},{"id":"2","role":"system","content":"后台活动","metadata":{"blockType":"execution"}},{"id":"3","role":"agent","content":"desire_status","metadata":{"blockType":"dynamicToolCall"}},{"id":"4","role":"agent","content":"Done","metadata":{"blockType":"outputMessage"}}]"#.utf8)
        let messages = try JSONDecoder().decode([JSONValue].self, from: data)
        let rows = ChatPresentation.rows(messages)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.activity), [false, true, false])
        XCTAssertEqual(rows.flatMap(\.messages), messages)
        XCTAssertEqual(rows[1].messages.count, 2)
    }
    func testHistoryDatesHandleBothTimestampFormats() {
        XCTAssertFalse(ChatPresentation.time("2026-09-12T23:49:25.235339Z").isEmpty)
        XCTAssertFalse(ChatPresentation.time("2026-09-12T23:49:25Z").isEmpty)
        XCTAssertEqual(ChatPresentation.time("invalid"), "")
        XCTAssertFalse(ChatPresentation.time("2026-09-12T23:49:25.235339Z").contains("2026-09-12T"))
    }
}
