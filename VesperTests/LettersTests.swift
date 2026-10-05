import XCTest
@testable import Vesper

@MainActor final class LettersTests: XCTestCase {
    func testScheduledDraftRestoresTheExactRetryPayload() throws {
        let api = APIClient(baseURL: "https://letters.example", historyURL: "https://letters.example", token: UUID().uuidString)
        var draft = LetterDraft()
        draft.title = "Evening"; draft.text = "A little thought\nfor tomorrow."; draft.scheduled = true
        draft.unlockAt = Date(timeIntervalSince1970: 1800000000); draft.deliveryAttempted = true
        try LetterDraftCache.save(draft, api: api)
        let restored = LetterDraftCache.load(api)
        XCTAssertEqual(restored, draft)
        XCTAssertEqual(restored.payload, draft.payload)
        var other = api; other.token = UUID().uuidString
        XCTAssertEqual(LetterDraftCache.load(other).text, "", "Drafts must remain isolated between connected accounts.")
        try LetterDraftCache.save(LetterDraft(), api: api)
    }
    func testSealedCoverDecodesWithoutReceivingItsBody() throws {
        let data = Data(#"{"id":"sealed","title":"For tomorrow","author":"Rowan","recipient":"Vera","createdAt":"2026-10-04T12:00:00Z","unlockAt":"2026-10-05T09:00:00.000Z","locked":true}"#.utf8)
        let letter = try JSONDecoder().decode(VesperLetter.self, from: data)
        XCTAssertTrue(letter.isLocked); XCTAssertNil(letter.text)
        XCTAssertNotNil(LetterDates.parse(letter.unlockAt!))
    }
    func testReplyDoesNotOverwriteAPendingDelivery() {
        let model = LettersStore(); model.draft.text = "My existing draft"; model.draft.deliveryAttempted = true
        let id = model.draft.id
        let letter = VesperLetter(id: "parent", title: "A thought", text: "Hello", author: "Rowan", createdAt: "2026-10-04T12:00:00Z")
        XCTAssertFalse(model.reply(to: letter))
        XCTAssertEqual(model.draft.id, id); XCTAssertEqual(model.draft.text, "My existing draft")
    }
    func testJournalRemainsInCollectionAndLettersHasItsOwnDestination() {
        XCTAssertTrue(VesperGridOrder.restore("[]").contains(.journal))
        XCTAssertFalse(VesperGridOrder.defaults.contains(.letters))
        XCTAssertEqual(Destination.letters.icon, "envelope")
    }
    func testInvalidOpeningDateLeavesTheDraftEditableWithoutAttemptingDelivery() async {
        let model = LettersStore()
        model.configure(APIClient(baseURL: "https://letters.example", historyURL: "https://letters.example", token: UUID().uuidString))
        model.draft.text = "A future thought"; model.draft.scheduled = true
        model.draft.unlockAt = Date().addingTimeInterval(11 * 366 * 86400)
        let result = await model.post()
        XCTAssertNil(result); XCTAssertFalse(model.draft.deliveryAttempted)
        XCTAssertEqual(model.status, "Choose an opening date within ten years.")
    }
}
