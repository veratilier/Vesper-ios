import XCTest
@testable import Vesper

@MainActor final class LocalDocumentsTests: XCTestCase {
    private var disk: LocalDocumentDisk!
    private let client = APIClient(baseURL: "https://local-first.example", historyURL: "https://local-first.example", token: "fixture-account")
    override func setUp() {
        super.setUp()
        disk = LocalDocumentDisk(directory: FileManager.default.temporaryDirectory.appendingPathComponent("local-doc-tests-" + UUID().uuidString))
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: disk.directory)
        super.tearDown()
    }
    private func row(_ id: String, _ text: String) -> JSONValue { .object(["id": .string(id), "text": .string(text)]) }
    private func seed(_ documents: [String: JSONValue]) throws {
        try disk.save(LocalDocumentSnapshot(documents: documents, lastSync: .now), api: client)
    }
    private func store(load: @escaping (APIClient) async throws -> JSONValue = { _ in throw URLError(.notConnectedToInternet) },
                       request: @escaping (APIClient, String, String, JSONValue?) async throws -> JSONValue = { _, _, _, _ in throw URLError(.notConnectedToInternet) }) -> AppStore {
        let value = AppStore(loadState: load, disk: disk, requestDocument: request)
        value.baseURL = client.baseURL; value.token = client.token
        return value
    }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testLocalDataUnlocksEntryBeforeCloudReadAndSurvivesOfflineRefresh() async throws {
        try seed(["notes": .array([row("one", "Saved note")]), "diary": .object(["today": .string("Saved diary")])])
        let value = store(); defer { value.token = "" }
        XCTAssertTrue(value.canEnter); XCTAssertFalse(value.connected)
        XCTAssertEqual(value.document("notes").array.first?["text"].string, "Saved note")
        await value.refresh()
        XCTAssertTrue(value.canEnter); XCTAssertFalse(value.connected)
        XCTAssertEqual(value.document("diary")["today"].string, "Saved diary")
    }

    func testOfflineEditIsDurableBeforeCloudAcknowledgmentAndRestoresAfterRestart() async throws {
        try seed(["notes": .array([row("one", "Before")])])
        let value = store(); defer { value.token = "" }
        let saved = await value.upsert("notes", item: row("one", "Offline edit"))
        XCTAssertTrue(saved)
        XCTAssertEqual(try disk.load(client)?.pending["notes"]?.value.array.first?["text"].string, "Offline edit")
        await eventually { value.syncError != nil }
        let restarted = store(); defer { restarted.token = "" }
        XCTAssertEqual(restarted.document("notes").array.first?["text"].string, "Offline edit")
        XCTAssertEqual(restarted.pendingDocuments.count, 1)
    }

    func testSyncPreservesOtherDeviceRowsAndUnknownFields() async throws {
        try seed(["notes": .array([row("one", "Before")])])
        var remote = JSONValue.array([.object(["id": .string("one"), "text": .string("Before"), "color": .string("blue")]), row("two", "Other device")])
        let value = store { _, _, method, body in
            if method == "GET" { return .object(["value": remote]) }
            remote = body!["value"]; return .object(["ok": .bool(true)])
        }
        defer { value.token = "" }
        let saved = await value.upsert("notes", item: row("one", "Local edit")); XCTAssertTrue(saved)
        await eventually { value.pendingDocuments.isEmpty }
        XCTAssertEqual(remote.array.map(\.id), ["one", "two"])
        XCTAssertEqual(remote.array[0]["color"].string, "blue")
        XCTAssertEqual(remote.array[0]["text"].string, "Local edit")
        XCTAssertTrue(try disk.load(client)!.pending.isEmpty)
    }

    func testConflictNeverOverwritesCloudAndRemainsDurable() async throws {
        try seed(["notes": .array([row("one", "Before")])])
        var puts = 0
        let remote = JSONValue.array([row("one", "Other device edit")])
        let value = store { _, _, method, _ in
            if method != "GET" { puts += 1 }
            return .object(["value": remote, "ok": .bool(true)])
        }
        defer { value.token = "" }
        _ = await value.upsert("notes", item: row("one", "My edit"))
        await eventually { value.conflictingDocuments.contains("notes") }
        XCTAssertEqual(puts, 0)
        XCTAssertEqual(value.document("notes").array[0]["text"].string, "My edit")
        XCTAssertNotNil(try disk.load(client)?.pending["notes"])
        await value.resolvePendingDocument("notes", keepLocal: false)
        XCTAssertTrue(value.pendingDocuments.isEmpty)
        XCTAssertEqual(value.document("notes"), remote)
    }

    func testEditDuringUploadRemainsQueuedOnTopOfAcknowledgedValue() async throws {
        try seed(["notes": .array([row("one", "Before")])])
        var remote = JSONValue.array([row("one", "Before")])
        var receipt: CheckedContinuation<JSONValue, Never>?
        var first = true
        let value = store { _, _, method, body in
            if method == "GET" { return .object(["value": remote]) }
            remote = body!["value"]
            if first { first = false; return await withCheckedContinuation { receipt = $0 } }
            return .object(["ok": .bool(true)])
        }
        defer { value.token = "" }
        _ = await value.upsert("notes", item: row("one", "First edit"))
        await eventually { receipt != nil }
        _ = await value.upsert("notes", item: row("one", "Second edit"))
        receipt?.resume(returning: .object(["ok": .bool(true)]))
        await eventually { !value.syncing }
        XCTAssertEqual(value.document("notes").array[0]["text"].string, "Second edit")
        await value.syncPendingDocuments()
        XCTAssertTrue(value.pendingDocuments.isEmpty)
        XCTAssertEqual(remote.array[0]["text"].string, "Second edit")
    }

    func testAccountSwitchRejectsLateReadsAndKeepsSeparateLocalReplicas() async throws {
        try seed(["notes": .array([row("one", "Account A")])])
        var other = client; other.token = "account-b"
        try disk.save(LocalDocumentSnapshot(documents: ["notes": .array([row("b", "Account B")])]), api: other)
        var read: CheckedContinuation<JSONValue, Never>?
        var puts = 0
        let value = store { _, _, method, _ in
            if method == "GET" { return await withCheckedContinuation { read = $0 } }
            puts += 1; return .object(["ok": .bool(true)])
        }
        defer { value.token = "" }
        _ = await value.upsert("notes", item: row("one", "Pending A"))
        await eventually { read != nil }
        value.token = other.token
        read?.resume(returning: .object(["value": .array([row("one", "Account A")])]))
        await Task.yield()
        XCTAssertEqual(puts, 0)
        XCTAssertEqual(value.document("notes").array[0]["text"].string, "Account B")
        XCTAssertTrue(value.pendingDocuments.isEmpty)
        XCTAssertNotNil(try disk.load(client)?.pending["notes"])
        value.token = ""
        XCTAssertTrue(value.documents.isEmpty); XCTAssertFalse(value.canEnter)
    }

    func testLateRefreshCannotReplacePendingLocalEdit() async throws {
        try seed(["notes": .array([row("one", "Before")])])
        var read: CheckedContinuation<JSONValue, Never>?
        let value = store(load: { _ in await withCheckedContinuation { read = $0 } })
        defer { value.token = "" }
        let refresh = Task { await value.refresh() }
        await eventually { read != nil }
        _ = await value.upsert("notes", item: row("one", "New local edit"))
        read?.resume(returning: .object(["documents": .object(["notes": .object(["value": .array([row("one", "Old cloud read")])])])]))
        await refresh.value
        XCTAssertEqual(value.document("notes").array[0]["text"].string, "New local edit")
        XCTAssertNotNil(try disk.load(client)?.pending["notes"])
    }

    func testLocalWriteFailureDoesNotClaimSavedOrDiscardPreviousData() async throws {
        try seed(["notes": .array([row("one", "Before")])])
        let value = store(); defer { value.token = "" }
        try FileManager.default.removeItem(at: disk.directory)
        try Data("not a directory".utf8).write(to: disk.directory)
        let saved = await value.upsert("notes", item: row("one", "Cannot save"))
        XCTAssertFalse(saved)
        XCTAssertEqual(value.document("notes").array[0]["text"].string, "Before")
        XCTAssertTrue(value.pendingDocuments.isEmpty)
    }

    func testThreeWayMergePreservesDeletionsAndBothDiaryAuthors() throws {
        let before = JSONValue.object(["user": .string("old"), "agent": .string("old"), "updatedAt": .string("2026-10-07T00:00:00Z")])
        var mine = before; mine["user"] = .string("Vera's edit"); mine["updatedAt"] = .string("2026-10-07T00:01:00Z")
        var theirs = before; theirs["agent"] = .string("Rowan's edit"); theirs["updatedAt"] = .string("2026-10-07T00:02:00.123Z")
        let merged = try XCTUnwrap(DocumentMerge.apply(base: before, local: mine, remote: theirs))
        XCTAssertEqual(merged["user"], mine["user"]); XCTAssertEqual(merged["agent"], theirs["agent"])
        XCTAssertEqual(merged["updatedAt"], theirs["updatedAt"])
        let removed = try DocumentMerge.apply(base: .array([row("a", "a")]), local: .array([]), remote: .array([row("a", "a"), row("b", "b")]))
        XCTAssertEqual(removed?.array.map(\.id), ["b"])
        XCTAssertThrowsError(try DocumentMerge.apply(base: .array([row("a", "a")]), local: .array([]), remote: .array([row("a", "changed")])))
    }
}
