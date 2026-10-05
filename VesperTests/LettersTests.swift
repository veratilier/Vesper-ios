import XCTest
import SwiftUI
import UIKit
@testable import Vesper

@MainActor final class LettersTests: XCTestCase {
    func testLetterBoxStaysWithinPhoneMarginsWhenBrowsingAndSelecting() throws {
        for width in [320, 393, 430] {
            for count in [1, 5] {
                let letters = (0..<count).map { VesperLetter(id: "layout-\($0)", title: "我们的第\($0 + 1)封信", author: "Vera", createdAt: "2026-10-05T06:00:00Z") }
                for selected in [false, true] {
                    let content = UprightLetters(letters: letters, hoverID: .constant(nil), selectedID: .constant(selected ? letters.last?.id : nil), colors: LetterColors(palette: .white))
                        .padding(.horizontal, 22).padding(.top, 12)
                        .frame(width: CGFloat(width), height: 420, alignment: .topLeading).background(Color.white)
                    let renderer = ImageRenderer(content: content); renderer.scale = 1
                    let image = try XCTUnwrap(renderer.uiImage)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Letters-\(width)-\(count)-\(selected ? "selected" : "resting")"; attachment.lifetime = .keepAlways; add(attachment)
                    var bytes = [UInt8](repeating: 0, count: width * 420 * 4)
                    try bytes.withUnsafeMutableBytes { raw in
                        let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: 420, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: width, height: 420))
                    }
                    let marked = (0..<(width * 420)).filter { pixel in
                        let offset = pixel * 4
                        return bytes[offset] < 200 || bytes[offset + 1] < 200 || bytes[offset + 2] < 200
                    }
                    XCTAssertFalse(marked.isEmpty)
                    XCTAssertGreaterThanOrEqual(marked.map { $0 % width }.min() ?? 0, 18, "Letter artwork must leave the left phone margin visible")
                    XCTAssertLessThanOrEqual(marked.map { $0 % width }.max() ?? width, width - 18, "Letter artwork must not run off the right edge")
                    XCTAssertGreaterThanOrEqual(marked.map { $0 / width }.min() ?? 0, 12, "A lifted envelope and date tab must remain inside the top of the canvas")
                    XCTAssertLessThan(marked.map { $0 / width }.max() ?? 420, 342, "The box must stay above the instructions below it")
                }
            }
        }
    }
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
