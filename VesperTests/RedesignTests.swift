import XCTest
@testable import Vesper

@MainActor final class RedesignTests: XCTestCase {
    func testDraftsSurviveShellAndConversationChanges() {
        let draft = ChatComposer()
        draft.draft = "unfinished main-room thought"
        draft.pendingMusic = .object(["id": .string("song")])
        draft.switchConversation(from: "main", to: "other")
        XCTAssertEqual(draft.draft, "")
        XCTAssertNil(draft.pendingMusic)
        draft.draft = "another draft"
        draft.switchConversation(from: "other", to: "main")
        XCTAssertEqual(draft.draft, "unfinished main-room thought")
        XCTAssertEqual(draft.pendingMusic?["id"].string, "song")
        draft.switchConversation(from: "main", to: "main")
        XCTAssertEqual(draft.draft, "unfinished main-room thought")
    }
    func testNoteLayoutRoundTripDoesNotNeedOrChangeBody() {
        let note: JSONValue = .object(["id": .string("one"), "text": .string("original body"), "kind": .string("agent")])
        var placement = NotePlacement(note, index: 4)
        XCTAssertEqual(placement.cardStyle, "letter")
        placement.x = 460; placement.rotation = -7; placement.cardStyle = "grid"
        var changed = note; changed["layout"] = placement.json
        XCTAssertEqual(NotePlacement(changed, index: 0), placement)
        XCTAssertEqual(changed["text"], note["text"])
    }
}
