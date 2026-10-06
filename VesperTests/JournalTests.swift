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

    func testMoodMultiSelectionSurvivesRoundTripAndEntryEdits() throws {
        let key = "2026-10-06"
        let happy = JournalDay.togglingMood(.happy, for: key, author: .vera, in: .null, updatedAt: "first")
        let both = JournalDay.togglingMood(.sweet, for: key, author: .vera, in: happy, updatedAt: "second")
        let data = try JSONEncoder().encode(both)
        let restored = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(restored[key]["moods"]["user"].array, [.string("happy"), .string("sweet")])
        let edited = JournalDay.savingVera("Today was lovely.", for: key, in: restored, updatedAt: "third")
        XCTAssertEqual(edited[key]["moods"], restored[key]["moods"])
        let removed = JournalDay.togglingMood(.happy, for: key, author: .vera, in: edited, updatedAt: "fourth")
        XCTAssertEqual(removed[key]["moods"]["user"].array, [.string("sweet")])
        let cleared = JournalDay.togglingMood(.sweet, for: key, author: .vera, in: removed, updatedAt: "last")
        XCTAssertEqual(cleared[key]["moods"]["user"].array, [])
        XCTAssertEqual(cleared[key]["user"].string, "Today was lovely.")
        XCTAssertEqual(cleared[key]["updatedAt"].string, "last")
    }

    func testMoodEditsPreserveOtherAuthorDatesAndUnknownData() {
        let key = "2026-10-06"
        let diary: JSONValue = .object([
            key: .object([
                "user": .string("Vera's entry"), "agent": .string("Rowan's entry"),
                "futureField": .number(7),
                "moods": .object([
                    "user": .array([.string("happy"), .string("future-mood")]),
                    "agent": .array([.string("calm")]),
                    "futureAuthor": .array([.string("quiet")])
                ])
            ]),
            "2026-10-05": .object(["moods": .object(["user": .array([.string("low")])])]),
            "metadata": .object(["version": .number(2)])
        ])
        let vera = JournalDay.togglingMood(.happy, for: key, author: .vera, in: diary, updatedAt: "now")
        XCTAssertEqual(vera[key]["moods"]["user"].array, [.string("future-mood")])
        XCTAssertEqual(vera[key]["moods"]["agent"], diary[key]["moods"]["agent"])
        let rowan = JournalDay.togglingMood(.hopeful, for: key, author: .rowan, in: vera, updatedAt: "later")
        XCTAssertEqual(rowan[key]["moods"]["agent"].array, [.string("calm"), .string("hopeful")])
        XCTAssertEqual(rowan[key]["moods"]["user"], vera[key]["moods"]["user"])
        XCTAssertEqual(rowan[key]["moods"]["futureAuthor"], diary[key]["moods"]["futureAuthor"])
        XCTAssertEqual(rowan[key]["user"], diary[key]["user"])
        XCTAssertEqual(rowan[key]["agent"], diary[key]["agent"])
        XCTAssertEqual(rowan[key]["futureField"], diary[key]["futureField"])
        XCTAssertEqual(rowan["2026-10-05"], diary["2026-10-05"])
        XCTAssertEqual(rowan["metadata"], diary["metadata"])
    }

    func testMoodVocabularyAndRecentsAreLimitedAndAuthorSpecific() {
        XCTAssertEqual(JournalMood.allCases.map(\.label), ["开心", "依恋", "想念", "安心", "满足", "释然", "好奇", "心动", "平静", "期待", "感动", "低落", "委屈", "孤独", "焦虑", "不安", "烦躁", "愤怒", "纠结", "尴尬", "愧疚", "无聊", "麻木", "疲惫"])
        XCTAssertEqual(JournalMood.recent(in: .null, author: .vera), Array(JournalMood.allCases.prefix(6)))
        var diary: JSONValue = .null
        let used: [JournalMood] = [.happy, .calm, .sweet, .curious, .tired, .missing, .secure]
        for (index, mood) in used.enumerated() {
            diary = JournalDay.togglingMood(mood, for: "2026-10-07", author: .vera, in: diary,
                updatedAt: "2026-10-07T01:00:0\(index)Z")
        }
        XCTAssertEqual(JournalMood.recent(in: diary, author: .vera), Array(used.reversed().prefix(6)))
        XCTAssertEqual(JournalMood.recent(in: diary, author: .rowan), Array(JournalMood.allCases.prefix(6)))
        let edited = JournalDay.savingVera("Edited later", for: "2026-10-07", in: diary, updatedAt: "2026-10-07T02:00:00Z")
        XCTAssertEqual(JournalMood.recent(in: edited, author: .vera), JournalMood.recent(in: diary, author: .vera))
        let deselected = JournalDay.togglingMood(.happy, for: "2026-10-07", author: .vera, in: edited, updatedAt: "2026-10-07T03:00:00Z")
        XCTAssertEqual(JournalMood.recent(in: deselected, author: .vera).first, .happy)
        XCTAssertFalse(deselected["2026-10-07"]["moods"]["user"].array.contains(.string("happy")))
    }

    @MainActor func testMoodSaveIsVerifiedFromTheServerAndSurvivesRefresh() async {
        URLProtocol.registerClass(JournalMoodPersistenceProtocol.self)
        defer { URLProtocol.unregisterClass(JournalMoodPersistenceProtocol.self) }
        JournalMoodPersistenceProtocol.reset(dropTags: false)
        let store = AppStore(); store.token = "synthetic-mood"; store.baseURL = "https://journal-mood-save.example"
        let saved = await store.mutate("diary", verifySavedValue: true) {
            JournalDay.togglingMood(.attached, for: "2026-10-07", author: .vera, in: $0, updatedAt: "now")
        }
        XCTAssertTrue(saved)
        await store.refresh()
        XCTAssertEqual(store.document("diary")["2026-10-07"]["moods"]["user"].array, [.string("attached")])
    }

    @MainActor func testMoodSaveDoesNotClaimSuccessWhenServerDropsTags() async {
        URLProtocol.registerClass(JournalMoodPersistenceProtocol.self)
        defer { URLProtocol.unregisterClass(JournalMoodPersistenceProtocol.self) }
        JournalMoodPersistenceProtocol.reset(dropTags: true)
        let store = AppStore(); store.token = "synthetic-mood"; store.baseURL = "https://journal-mood-save.example"
        let saved = await store.mutate("diary", reportErrors: false, verifySavedValue: true) {
            JournalDay.togglingMood(.attached, for: "2026-10-07", author: .vera, in: $0, updatedAt: "now")
        }
        XCTAssertFalse(saved)
        XCTAssertEqual(store.document("diary"), .null)
    }
}

private final class JournalMoodPersistenceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var value: JSONValue = .null
    private static var dropTags = false
    static func reset(dropTags: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = .null; self.dropTags = dropTags
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "journal-mood-save.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let response: JSONValue
        if request.httpMethod == "PUT" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(buffer, count: count)
                }
            }
            let input = try! JSONDecoder().decode(JSONValue.self, from: body)
            Self.value = input["value"]
            if Self.dropTags { Self.value["2026-10-07"]["moods"] = .null }
            response = .object(["ok": .bool(true)])
        } else if request.url?.query == nil {
            response = .object(["documents": .object(["diary": .object(["value": Self.value])])])
        } else { response = .object(["value": Self.value]) }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
