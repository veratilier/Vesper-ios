import XCTest
@testable import Vesper

final class JournalTests: XCTestCase {
    func testBeijingDiaryDatesAcrossMidnightAndLeapDay() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T16:30:00Z"))
        XCTAssertEqual(JournalDay.key(instant), "2026-10-06")
        let leap = try XCTUnwrap(JournalDay.date("2024-02-29"))
        XCTAssertEqual(JournalDay.key(JournalDay.moving(leap, by: -1)), "2024-02-28")
        XCTAssertEqual(JournalDay.key(JournalDay.moving(leap, by: 1)), "2024-03-01")
        XCTAssertNil(JournalDay.date("2026-02-29"))
        XCTAssertNil(JournalDay.date("2026-10-06-extra"))
    }

    func testDateRailIncludesDistantEntriesAndFiltersMetadata() throws {
        let today = try XCTUnwrap(JournalDay.date("2026-10-06"))
        let diary: JSONValue = .object([
            "2025-01-01": .object(["agent": .string("An older entry")]),
            "2026-10-06": .object(["user": .string("Today")]),
            "metadata": .object(["version": .number(2)])
        ])
        let rail = JournalDay.rail(around: today, diary: diary, today: today)
        XCTAssertTrue(rail.contains("2025-01-01"))
        XCTAssertTrue(rail.contains("2026-09-22"))
        XCTAssertTrue(rail.contains("2026-10-20"))
        XCTAssertFalse(rail.contains("metadata"))
        XCTAssertEqual(rail.filter { $0 == "2026-10-06" }.count, 1)
        XCTAssertEqual(rail, rail.sorted())
    }

    func testSavingVeraPreservesRowanOtherDaysAndUnknownFields() {
        let diary: JSONValue = .object([
            "2026-10-05": .object(["user": .string("Yesterday")]),
            "2026-10-06": .object(["user": .string("Old draft"), "agent": .string("Rowan's entry"),
                "futureField": .array([.number(7)])]),
            "metadata": .object(["version": .number(2)])
        ])
        let saved = JournalDay.savingVera("New draft", for: "2026-10-06", in: diary, updatedAt: "now")
        XCTAssertEqual(saved["2026-10-06"]["user"].string, "New draft")
        XCTAssertEqual(saved["2026-10-06"]["agent"], diary["2026-10-06"]["agent"])
        XCTAssertEqual(saved["2026-10-06"]["futureField"], diary["2026-10-06"]["futureField"])
        XCTAssertEqual(saved["2026-10-05"], diary["2026-10-05"])
        XCTAssertEqual(saved["metadata"], diary["metadata"])
        let cleared = JournalDay.savingVera("", for: "2026-10-06", in: saved, updatedAt: "later")
        XCTAssertEqual(cleared["2026-10-06"]["user"].string, "")
        XCTAssertEqual(cleared["2026-10-06"]["agent"], diary["2026-10-06"]["agent"])
        let first = JournalDay.savingVera("First entry", for: "2026-10-06", in: .null, updatedAt: "now")
        XCTAssertEqual(first["2026-10-06"]["user"].string, "First entry")
    }
}
