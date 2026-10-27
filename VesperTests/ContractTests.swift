import XCTest
import Combine
import SwiftUI
import UIKit
import CryptoKit
@testable import Vesper

final class ChatTokenUsageTests: XCTestCase {
    private func counts(_ input: Int, _ cached: Int?, _ output: Int, reasoning: Int = 0) -> JSONValue {
        var value: JSONValue = .object(["inputTokens": .number(Double(input)), "outputTokens": .number(Double(output)),
                                       "reasoningOutputTokens": .number(Double(reasoning)), "totalTokens": .number(Double(input + output))])
        if let cached { value["cachedInputTokens"] = .number(Double(cached)) }
        return value
    }
    private func event(_ total: JSONValue, _ last: JSONValue, turn: String = "turn", thread: String = "thread") -> JSONValue {
        .object(["threadId": .string(thread), "turnId": .string(turn), "tokenUsage": .object(["total": total, "last": last])])
    }
    func testToolRoundsAreAggregatedAndDuplicateUpdatesDoNotDoubleCount() throws {
        var tracker = ChatTurnTokenUsageTracker()
        tracker.begin(thread: "thread", turn: "turn")
        let first = event(counts(10_000, 8_000, 100), counts(10_000, 8_000, 100))
        _ = tracker.observe(first); _ = tracker.observe(first)
        let final = try XCTUnwrap(tracker.observe(event(counts(22_000, 19_000, 300, reasoning: 90), counts(12_000, 11_000, 200, reasoning: 90))))
        let usage = try XCTUnwrap(ChatTokenUsage(final))
        XCTAssertEqual(usage.total, 22_300); XCTAssertEqual(usage.output, 300)
        XCTAssertEqual(try XCTUnwrap(usage.cacheHitRate), 19_000.0 / 22_000.0, accuracy: 0.00001)
        tracker.finish(thread: "thread", turn: "turn")
        XCTAssertEqual(tracker.snapshot(thread: "thread", turn: "turn")?["complete"], .bool(true))
        tracker.begin(thread: "thread", turn: "next")
        let next = try XCTUnwrap(tracker.observe(event(counts(35_000, 31_000, 450, reasoning: 90), counts(13_000, 12_000, 150), turn: "next")))
        XCTAssertEqual(ChatTokenUsage(next)?.total, 13_150, "One reply must not show lifetime thread usage")
    }
    func testFirstUpdateDerivesBaselineAndReconnectReportsOnlyKnownRequest() throws {
        let total = counts(100_000, 90_000, 2_000), last = counts(20_000, 19_000, 200)
        var tracker = ChatTurnTokenUsageTracker()
        tracker.begin(thread: "thread", turn: "turn")
        XCTAssertEqual(ChatTokenUsage(try XCTUnwrap(tracker.observe(event(total, last))))?.total, 20_200)
        var resumed = ChatTurnTokenUsageTracker()
        let partial = try XCTUnwrap(resumed.observe(event(total, last)))
        XCTAssertEqual(partial["scope"].string, "latestRequest")
        XCTAssertEqual(ChatTokenUsage(partial)?.total, 20_200)
        XCTAssertNil(tracker.snapshot(thread: "other", turn: "turn"))
    }
    func testMissingCacheIsUnknownAndReasoningIsNotAddedTwice() throws {
        let unknown = try XCTUnwrap(ChatTokenUsage(counts(100, nil, 30, reasoning: 20)))
        XCTAssertNil(unknown.cacheHitRate); XCTAssertEqual(unknown.total, 130)
        XCTAssertEqual(ChatTokenUsage(counts(100, 0, 30))?.cacheHitRate, 0)
        XCTAssertNil(ChatTokenUsage(counts(100, 101, 30)))
        XCTAssertNil(ChatTokenUsage(.object(["totalTokens": .number(0)])))
    }
    func testHistoryRefreshRetainsVerifiedLocalUsageForSameReply() {
        var local: JSONValue = .object(["id": .string("reply"), "status": .string("delivered"),
            "metadata": .object(["threadId": .string("thread"), "turnId": .string("turn")])])
        let cloud = local
        local["metadata"]["tokenUsage"] = counts(100, 80, 20)
        XCTAssertNotEqual(ChatTranscript.merge([local], incoming: [cloud], tombstones: [])[0]["metadata"]["tokenUsage"], .null)
        var other = cloud; other["metadata"]["turnId"] = .string("other")
        XCTAssertEqual(ChatTranscript.merge([local], incoming: [other], tombstones: [])[0]["metadata"]["tokenUsage"], .null)
    }
}

final class ChatOrganizationTests: XCTestCase {
    func testLegacyProjectsKeepInstructionsAndGainIndependentProjectPins() throws {
        let old = Data(#"{"projects":[{"id":"p","name":"Study","instructions":"Original"}],"memberships":{"c":"p"},"pinned":["c"],"contactInstructions":"Keep"}"#.utf8)
        var value = try JSONDecoder().decode(ChatOrganization.self, from: old)
        var project = try XCTUnwrap(value.projects.first)
        XCTAssertEqual(project.symbol, "folder")
        XCTAssertEqual(value.project(for: "c")?.instructions, "Original")
        project.icon = "pawprint"; value.projects = [project]; value.togglePin(project)
        let restored = try JSONDecoder().decode(ChatOrganization.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(restored.isPinned(project)); XCTAssertEqual(restored.projects.first?.symbol, "pawprint")
        value.removeProject("p")
        XCTAssertTrue(value.pinned.contains("c")); XCTAssertFalse(value.isPinned(project))
        XCTAssertEqual(value.contactInstructions, "Keep")
    }

    func testProjectsPinsAndContactInstructionsStayScopedAndPersist() throws {
        let suite = "ChatOrganization-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vps = APIClient(baseURL: "https://vps.fixture", historyURL: "https://vps.fixture/history", token: "fixture")
        let mac = APIClient(baseURL: "https://mac.fixture", historyURL: "https://mac.fixture/history", token: "fixture")
        var otherAccount = vps; otherAccount.token = "another-fixture"
        var value = ChatOrganization()
        let project = ChatProject(name: "Study", instructions: "Use Chinese and English terms.")
        value.projects = [project]; value.move("same-room", to: project.id)
        value.pinned.insert("same-room"); value.contactInstructions = "Contact fixture"
        try value.save(vps, defaults: defaults)
        XCTAssertEqual(ChatOrganization.load(vps, defaults: defaults), value)
        XCTAssertTrue(ChatOrganization.load(mac, defaults: defaults).projects.isEmpty)
        XCTAssertTrue(ChatOrganization.load(otherAccount, defaults: defaults).pinned.isEmpty)
        XCTAssertTrue(value.instructions(for: "same-room", fallback: "Legacy").contains(project.instructions))
        XCTAssertFalse(value.instructions(for: "other-room", fallback: "Legacy").contains(project.instructions))
        value.move("same-room", to: nil)
        XCTAssertFalse(value.instructions(for: "same-room", fallback: "Legacy").contains(project.instructions))
        value.move("same-room", to: project.id)
        value.removeProject(project.id)
        XCTAssertNil(value.project(for: "same-room"))
        XCTAssertTrue(value.memberships.isEmpty)
        XCTAssertTrue(value.pinned.contains("same-room"), "Removing a folder must not delete or unpin its conversations")
        value.contactInstructions = ""
        XCTAssertEqual(value.instructions(for: "same-room", fallback: "Legacy"), "")
        try value.save(vps, defaults: defaults)
        XCTAssertEqual(ChatOrganization.load(vps, defaults: defaults).contactInstructions, "")
        var unconfigured = vps; unconfigured.token = ""
        XCTAssertThrowsError(try value.save(unconfigured, defaults: defaults))
    }
}

final class ChatHistoryUploadProjectionTests: XCTestCase {
    func testDownloadedHistoryKeepsLocalPhotoReferenceFromOlderUpload() {
        let attachment: JSONValue = .object([
            "name": .string("photo.jpg"), "type": .string("image/jpeg"),
            "url": .string("https://api.example.test/api/media/photo"), "key": .string("photo")
        ])
        let local: JSONValue = .object(["id": .string("photo-message"), "status": .string("delivered"),
                                        "metadata": .object(["attachments": .array([attachment])])])
        var oldCloud = local
        oldCloud["metadata"]["attachments"] = .array([.object([
            "name": .string("photo.jpg"), "type": .string("image/jpeg")
        ])])
        let merged = ChatTranscript.merge([local], incoming: [oldCloud], tombstones: [])
        XCTAssertEqual(merged.first?["metadata"]["attachments"].array.first?["url"], attachment["url"])
        XCTAssertEqual(merged.first?["metadata"]["attachments"].array.first?["key"], attachment["key"])
    }

    func testFileEncodingOutputIsOmittedOnlyFromNetworkCopy() throws {
        let output = String(repeating: "UEsDBA==", count: 2_000) + "\n... 100 bytes truncated ...\nQUJDRA=="
        let original: JSONValue = .object([
            "id": .string("execution-1"), "role": .string("system"), "content": .string("Terminal"),
            "metadata": .object(["execution": .object([
                "type": .string("commandExecution"), "title": .string("Terminal"),
                "command": .array([.string("/bin/bash"), .string("-lc"), .string("base64 -w0 /tmp/book.epub")]),
                "output": .string(output)])])
        ])
        let projected = ChatHistoryUploadProjection.body(original, path: "/conversations/room/messages", method: "POST", history: true)
        XCTAssertEqual(projected.id, original.id)
        XCTAssertEqual(projected["role"], original["role"])
        XCTAssertEqual(projected["metadata"]["execution"]["fileEncoding"]["name"], .string("book.epub"))
        XCTAssertEqual(projected["metadata"]["execution"]["fileEncoding"]["format"], .string("epub"))
        XCTAssertFalse(projected.pretty.contains("UEsDBA"))
        XCTAssertFalse(projected.pretty.contains("/tmp/book.epub"))
        XCTAssertEqual(original["metadata"]["execution"]["output"], .string(output), "The local record must stay intact")
        XCTAssertLessThan(try JSONEncoder().encode(projected).count, try JSONEncoder().encode(original).count)
    }

    func testShellWrappedAndChunkedFileOutputOnlySyncsMetadata() throws {
        let commands = [
            "/bin/bash -lc \"base64 -w0 '/tmp/Test Book.epub'\"",
            "/bin/bash -lc \"dd if='/tmp/Test Book.epub' bs=600000 skip=1 count=1 status=none | base64 -w0\""
        ]
        for (index, command) in commands.enumerated() {
            let original: JSONValue = .object([
                "id": .string("chunk-\(index)"), "role": .string("system"), "content": .string(command),
                "metadata": .object(["execution": .object([
                    "type": .string("commandExecution"), "command": .string(command),
                    "output": .string(String(repeating: "UEsDBA==", count: 100_000))])])
            ])
            let projected = ChatHistoryUploadProjection.message(original)
            XCTAssertEqual(projected["metadata"]["execution"]["fileEncoding"]["name"], .string("Test Book.epub"))
            XCTAssertEqual(projected["metadata"]["execution"]["fileEncoding"]["format"], .string("epub"))
            XCTAssertFalse(projected.pretty.contains("UEsDBA"))
            XCTAssertLessThan(try JSONEncoder().encode(projected).count, 2_000)
            XCTAssertEqual(original["metadata"]["execution"]["output"].string.count, 800_000)
        }
    }

    func testOrdinaryTextAndNonFileToolOutputRemainComplete() {
        let ordinary: JSONValue = .object([
            "content": .string("UEsDBA=="),
            "metadata": .object(["execution": .object([
                "type": .string("commandExecution"), "command": .string("echo sample"),
                "output": .string("UEsDBA==")])])
        ])
        XCTAssertEqual(ChatHistoryUploadProjection.message(ordinary), ordinary)
        XCTAssertEqual(ChatHistoryUploadProjection.body(ordinary, path: "/api/media", method: "POST", history: false), ordinary)
        let plain: JSONValue = .object(["content": .string("Ordinary message"), "metadata": .object([
            "attachments": .array([]), "modelInputText": .string("Ordinary message")])])
        XCTAssertEqual(ChatHistoryUploadProjection.message(plain), plain)
    }

    func testAttachmentMetadataAndModelPromptAreProjectedForHistoryAndMemory() {
        let file: JSONValue = .object([
            "name": .string("book.epub"), "type": .string("application/epub+zip"), "size": .number(42),
            "createdAt": .string("2026-10-20T03:58:17Z"), "url": .string("https://example.test/private?signature=secret"),
            "key": .string("opaque-key"), "base64": .string("UEsDBA=="), "thumbnail": .string("data:image/jpeg;base64,abc")
        ])
        let original: JSONValue = .object(["content": .string("Here is the file"), "metadata": .object([
            "attachments": .array([file]), "modelInputText": .string("File preview and signed URL")])])
        let projected = ChatHistoryUploadProjection.message(original)
        XCTAssertEqual(projected["content"], original["content"])
        XCTAssertEqual(projected["metadata"]["attachments"].array.first?["name"], .string("book.epub"))
        XCTAssertEqual(projected["metadata"]["attachments"].array.first?["size"], .number(42))
        XCTAssertEqual(projected["metadata"]["attachments"].array.first?["url"], file["url"])
        XCTAssertEqual(projected["metadata"]["attachments"].array.first?["key"], file["key"])
        XCTAssertEqual(projected["metadata"]["attachments"].array.first?["base64"], .null)
        XCTAssertEqual(projected["metadata"]["attachments"].array.first?["thumbnail"], .null)
        XCTAssertEqual(projected["metadata"]["modelInputText"], .null)
        XCTAssertEqual(original["metadata"]["attachments"].array.first?["base64"], .string("UEsDBA=="))
        let memory = ChatHistoryUploadProjection.body(.object(["attachments": .array([file])]),
                                                      path: "/api/memory/messages", method: "POST", history: false)
        XCTAssertEqual(memory["attachments"].array.first?["key"], file["key"])
        XCTAssertEqual(memory["attachments"].array.first?["url"], file["url"])
    }
}

final class BackendConnectionTests: XCTestCase {
    func testMacProfileNeverOverwritesLegacyVPSAddresses() throws {
        let suite = "VesperBackendTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = BackendConnection(baseURL: "https://original.example", historyURL: "https://original.example/history", socketURL: "wss://original.example")
        original.save(.vps, defaults: defaults)
        let backup = BackendConnection(baseURL: "https://backup.example", historyURL: "https://backup.example/history", socketURL: "wss://backup.example/chat")
        backup.save(.mac, defaults: defaults)
        XCTAssertEqual(BackendConnection.load(.vps, defaults: defaults), original)
        XCTAssertEqual(BackendConnection.load(.mac, defaults: defaults), backup)
        XCTAssertEqual(VesperBackend.vps.credentialAccount, "device-token")
        XCTAssertNotEqual(VesperBackend.vps.credentialAccount, VesperBackend.mac.credentialAccount)
    }
    func testOnlySecureAddressesWithoutInlineChatCredentialsAreAccepted() throws {
        try BackendConnection.load(.mac).validate()
        for socket in ["ws://backup.example/chat", "wss://backup.example/chat?token=secret", "wss://user:secret@backup.example/chat"] {
            XCTAssertThrowsError(try BackendConnection(baseURL: "https://backup.example", historyURL: "https://backup.example/history", socketURL: socket).validate())
        }
    }
    @MainActor func testFailedSavePreservesConnectionAndDocuments() async {
        let store = AppStore(loadState: { _ in throw ServiceError(message: "offline test") })
        let before = BackendConnection(baseURL: store.baseURL, historyURL: store.historyURL, socketURL: store.socketURL)
        let backend = store.activeBackend, token = store.token
        store.documents["profile"] = .object(["mainConversationId": .string("original-vps-room")])
        let switched = await store.saveConnection(connection: .load(.mac), credential: "synthetic-mac-token")
        XCTAssertFalse(switched)
        XCTAssertEqual(store.activeBackend, backend)
        XCTAssertEqual(BackendConnection(baseURL: store.baseURL, historyURL: store.historyURL, socketURL: store.socketURL), before)
        XCTAssertEqual(store.token, token)
        XCTAssertEqual(store.document("profile")["mainConversationId"].string, "original-vps-room")
    }
    @MainActor func testBusyWindowPreventsItsConnectionChange() async {
        var reads = 0
        let store = AppStore(loadState: { _ in reads += 1; return .object(["documents": .object([:])]) })
        let original = store.activeBackend
        let switched = await store.saveConnection(connection: .load(.mac), credential: "fixture", canSave: { false })
        XCTAssertFalse(switched)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(store.activeBackend, original)
    }
    @MainActor func testSuccessfulSaveUsesValidatedSnapshotAndTargetLocalEdits() async throws {
        let defaults = UserDefaults.standard
        let keys = ["apiURL", "historyURL", "socketURL", "vesper.activeBackend"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let previousToken = try CredentialStore.load(account: VesperBackend.vps.credentialAccount)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            if previousToken.isEmpty { try? CredentialStore.delete(account: VesperBackend.vps.credentialAccount) }
            else { try? CredentialStore.save(previousToken, account: VesperBackend.vps.credentialAccount) }
            try? FileManager.default.removeItem(at: directory)
        }
        let disk = LocalDocumentDisk(directory: directory)
        let connection = BackendConnection(baseURL: "https://switch-fixture.invalid", historyURL: "https://switch-fixture.invalid/history", socketURL: "wss://switch-fixture.invalid/chat")
        let target = APIClient(baseURL: connection.baseURL, historyURL: connection.historyURL, token: "synthetic-switch-token")
        let localNote: JSONValue = .array([.object(["id": .string("target-note"), "text": .string("Offline edit on this backend")])])
        try disk.save(LocalDocumentSnapshot(documents: ["notes": localNote], pending: ["notes": PendingDocument(base: .array([]), value: localNote)]), api: target)
        var reads = 0
        let store = AppStore(loadState: { candidate in
            reads += 1
            XCTAssertEqual(candidate.baseURL, connection.baseURL)
            return .object(["documents": .object([
                "profile": .object(["value": .object(["mainConversationId": .string("target-room")])]),
                "notes": .object(["value": .array([])])])])
        }, disk: disk, requestDocument: { _, _, _, _ in throw URLError(.notConnectedToInternet) })
        store.documents["profile"] = .object(["mainConversationId": .string("old-room")])
        let switched = await store.saveConnection(connection: connection, credential: target.token)
        XCTAssertTrue(switched)
        XCTAssertTrue(store.connected)
        XCTAssertEqual(reads, 1, "A switch should not add another state read after changing the active connection.")
        XCTAssertEqual(store.document("profile")["mainConversationId"].string, "target-room")
        XCTAssertEqual(store.document("notes"), localNote)
        XCTAssertNotNil(store.pendingDocuments["notes"])
        XCTAssertEqual(BackendConnection.load(.vps), connection)
    }
    func testLocalSnapshotsAreSeparatedEvenWithSameCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LocalDocumentDisk(directory: directory)
        let vps = APIClient(baseURL: "https://vps.example", historyURL: "https://vps.example/history", token: "fixture")
        let mac = APIClient(baseURL: "https://mac.example", historyURL: "https://mac.example/history", token: "fixture")
        try disk.save(LocalDocumentSnapshot(documents: ["profile": .object(["mainConversationId": .string("vps-only")])]), api: vps)
        XCTAssertNil(try disk.load(mac))
        try disk.save(LocalDocumentSnapshot(documents: ["profile": .object(["mainConversationId": .string("mac-only")])]), api: mac)
        XCTAssertEqual(try disk.load(vps)?.documents["profile"]?["mainConversationId"].string, "vps-only")
    }
}

@MainActor final class ChatBackendWorkspaceTests: XCTestCase {
    func testOpeningMacWhileVPSRepliesKeepsBothStreamsDraftsAndToolRecords() async throws {
        let vpsStore = AppStore(backend: .vps), macStore = AppStore(backend: .mac)
        vpsStore.token = "synthetic-vps-stream"; macStore.token = "synthetic-mac-stream"
        let vpsSocket = RecoverySocket(), macSocket = RecoverySocket()
        macSocket.snapshot["thread"]["id"] = .string("mac-thread")
        let vps = ChatSession(socketFactory: { _ in vpsSocket }, heartbeatInterval: 1000)
        let mac = ChatSession(socketFactory: { _ in macSocket }, heartbeatInterval: 1000)
        defer { vps.disconnect(); mac.disconnect() }
        vps.configureConnection(api: vpsStore.api, endpoint: "wss://vps.fixture", threadID: "thread")
        mac.configureConnection(api: macStore.api, endpoint: "wss://mac.fixture", threadID: "mac-thread")
        let workspace = ChatBackendWorkspace(vpsStore: vpsStore, vpsChat: vps, macStore: macStore, macChat: mac)
        vps.composer.draft = "VPS draft"; mac.composer.draft = "MAC draft"
        vps.model = "vps-model"; mac.model = "mac-model"
        vps.effort = "high"; mac.effort = "medium"
        try await vps.connect(); try await mac.connect()
        for socket in [vpsSocket, macSocket] {
            try socket.emit(.object(["method": .string("turn/started"), "params": .object(["turn": .object(["id": .string("same-turn")])])]))
        }
        await eventually { vps.busy && mac.busy }
        // Moving to the other window never disconnects either transport.
        try workspace.select(.mac)
        try vpsSocket.emit(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("same-item"), "delta": .string("VPS reply")])]))
        try macSocket.emit(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("same-item"), "delta": .string("MAC reply")])]))
        try vpsSocket.emit(.object(["method": .string("item/started"), "params": .object(["item": .object(["id": .string("tool"), "type": .string("commandExecution"), "command": .string("VPS command")])])]))
        try macSocket.emit(.object(["method": .string("item/started"), "params": .object(["item": .object(["id": .string("tool"), "type": .string("commandExecution"), "command": .string("MAC command")])])]))
        await eventually { vps.messages.count == 2 && mac.messages.count == 2 }
        try workspace.select(.vps)
        XCTAssertEqual(vpsSocket.closeCode, .invalid)
        XCTAssertEqual(macSocket.closeCode, .invalid)
        XCTAssertEqual(vps.messages.first { $0.id == "same-item" }?["content"].string, "VPS reply")
        XCTAssertEqual(mac.messages.first { $0.id == "same-item" }?["content"].string, "MAC reply")
        XCTAssertEqual(vps.messages.first { $0.id == "execution-tool" }?["metadata"]["execution"]["command"].string, "VPS command")
        XCTAssertEqual(mac.messages.first { $0.id == "execution-tool" }?["metadata"]["execution"]["command"].string, "MAC command")
        XCTAssertEqual(vps.composer.draft, "VPS draft"); XCTAssertEqual(mac.composer.draft, "MAC draft")
        XCTAssertEqual(vps.model, "vps-model"); XCTAssertEqual(mac.model, "mac-model")
        XCTAssertEqual(vps.effort, "high"); XCTAssertEqual(mac.effort, "medium")
        XCTAssertTrue(vps.busy); XCTAssertTrue(mac.busy)
    }
    func testUnconfiguredWindowDoesNotNavigateOrReplaceCurrentRuntime() throws {
        let vpsStore = AppStore(), macStore = AppStore(backend: .mac)
        macStore.token = ""
        let vps = ChatSession(), mac = ChatSession()
        let workspace = ChatBackendWorkspace(vpsStore: vpsStore, vpsChat: vps, macStore: macStore, macChat: mac)
        XCTAssertThrowsError(try workspace.select(.mac, openChat: true))
        XCTAssertEqual(workspace.selectedBackend, .vps)
        XCTAssertTrue(workspace.runtime(.vps).chat === vps)
        XCTAssertTrue(workspace.runtime(.mac).chat === mac)
    }
    func testMacCanSendWhileVPSIsStillReplying() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: directory)
        let vpsSocket = RecoverySocket(), macSocket = RecoverySocket()
        macSocket.snapshot["thread"]["id"] = .string("mac-thread")
        let vps = ChatSession(socketFactory: { _ in vpsSocket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let mac = ChatSession(socketFactory: { _ in macSocket }, heartbeatInterval: 1000, sendOutbox: outbox)
        defer { vps.disconnect(); mac.disconnect(); outbox.stop(); http.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let vpsStore = AppStore(), macStore = AppStore(backend: .mac)
        vpsStore.token = "synthetic-vps-send"; macStore.token = "synthetic-mac-send"
        vps.configureConnection(api: APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example/vps", token: vpsStore.token, requestSession: http), endpoint: "wss://send-preparation.example/vps", threadID: "thread")
        mac.configureConnection(api: APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example/mac", token: macStore.token, requestSession: http), endpoint: "wss://send-preparation.example/mac", threadID: "mac-thread")
        let workspace = ChatBackendWorkspace(vpsStore: vpsStore, vpsChat: vps, macStore: macStore, macChat: mac)
        try await vps.connect()
        vps.busy = true; vps.composer.draft = "Keep the VPS draft"
        try workspace.select(.mac, openChat: true)
        let sent = await mac.send("Send only to Mac")
        XCTAssertTrue(sent, mac.error ?? "Mac send failed")
        let turn = try XCTUnwrap(macSocket.packets.first { $0["method"].string == "turn/start" })
        XCTAssertEqual(turn["params"]["threadId"].string, "mac-thread")
        XCTAssertFalse(vpsSocket.packets.contains { $0["method"].string == "turn/start" })
        XCTAssertEqual(vpsSocket.closeCode, .invalid)
        XCTAssertTrue(vps.busy)
        XCTAssertEqual(vps.composer.draft, "Keep the VPS draft")
        XCTAssertTrue(mac.messages.contains { $0["content"].string == "Send only to Mac" && $0["status"].string == "delivered" })
    }
    func testSavingMacConnectionKeepsVPSWindowAndPreferenceUntouched() async throws {
        let defaults = UserDefaults.standard, priorSelection = defaults.object(forKey: "vesper.activeBackend")
        let keys = ["apiURL", "historyURL", "socketURL"].map { VesperBackend.mac.key($0) }
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let oldToken = try CredentialStore.load(account: VesperBackend.mac.credentialAccount)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            if let priorSelection { defaults.set(priorSelection, forKey: "vesper.activeBackend") } else { defaults.removeObject(forKey: "vesper.activeBackend") }
            if oldToken.isEmpty { try? CredentialStore.delete(account: VesperBackend.mac.credentialAccount) }
            else { try? CredentialStore.save(oldToken, account: VesperBackend.mac.credentialAccount) }
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("vps", forKey: "vesper.activeBackend")
        let vpsStore = AppStore(), vps = ChatSession(), mac = ChatSession()
        vps.messages = [.object(["id": .string("vps-message"), "content": .string("Still replying")])]
        vps.composer.draft = "Keep me"
        let originalAPI = vpsStore.api
        let macStore = AppStore(backend: .mac, loadState: { _ in .object([
            "documents": .object(["profile": .object(["value": .object(["mainConversationId": .string("mac-room")])])]),
            "backend": .object(["backend": .string("mac"), "backendId": .string("fixture-mac")])]) },
            loadHistoryHealth: { _ in .object(["backendId": .string("fixture-mac")]) }, disk: LocalDocumentDisk(directory: directory))
        let workspace = ChatBackendWorkspace(vpsStore: vpsStore, vpsChat: vps, macStore: macStore, macChat: mac)
        let connection = BackendConnection(baseURL: "https://mac.fixture", historyURL: "https://mac.fixture/history", socketURL: "wss://mac.fixture/chat")
        let savedOK = await macStore.saveConnection(connection: connection, credential: "synthetic-mac-token")
        XCTAssertTrue(savedOK)
        XCTAssertEqual(workspace.selectedBackend, .vps)
        XCTAssertEqual(vpsStore.activeBackend, .vps)
        XCTAssertEqual(vpsStore.api.baseURL, originalAPI.baseURL)
        XCTAssertEqual(vpsStore.api.token, originalAPI.token)
        XCTAssertEqual(vps.messages.first?.id, "vps-message")
        XCTAssertEqual(vps.composer.draft, "Keep me")
        XCTAssertEqual(macStore.document("profile")["mainConversationId"].string, "mac-room")
        XCTAssertEqual(defaults.string(forKey: "vesper.activeBackend"), "vps")
        XCTAssertEqual(BackendConnection.load(.mac), connection)
        XCTAssertNotEqual(BackendConnection.load(.vps), connection)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor private final class SuspendedContactRequests {
    private(set) var waits: [(String, CheckedContinuation<JSONValue, Error>)] = []
    private var released = false
    private func response(_ path: String) -> JSONValue {
        path.contains("profile") ? .object(["value": .object(["agentName": .string("Old Mac"), "mainConversationId": .string("old-room")])])
            : .object(["conversations": .array([.object(["id": .string("old-room")])])])
    }
    func read(_ path: String) async throws -> JSONValue {
        if released { return response(path) }
        return try await withCheckedThrowingContinuation { waits.append((path, $0)) }
    }
    func release() {
        released = true; let pending = waits; waits = []
        for (path, continuation) in pending { continuation.resume(returning: response(path)) }
    }
}

@MainActor final class ChatBackendContactTests: XCTestCase {
    func testEqualRoomIDsKeepBackendAvatarsAndPreviewsInSeparateLocalCaches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LocalDocumentDisk(directory: directory.appendingPathComponent("documents"))
        let contacts = ChatBackendContacts(cacheRoot: directory, disk: disk, request: { api, path, _ in
            let label = api.baseURL.contains("vps") ? "VPS" : "MAC"
            if path.contains("profile") { return .object(["value": .object(["agentName": .string(label), "agentAvatar": .string(label + "-avatar"), "mainConversationId": .string("same-room")])]) }
            return .object(["conversations": .array([
                .object(["id": .string("same-room"), "preview": .string(label + " message")]),
                .object(["id": .string("another-room"), "title": .string(label + " project"), "preview": .string(label + " second window")])
            ])])
        })
        let vps = APIClient(baseURL: "https://vps.fixture", historyURL: "https://vps.fixture/history", token: "same-synthetic-token")
        let mac = APIClient(baseURL: "https://mac.fixture", historyURL: "https://mac.fixture/history", token: "same-synthetic-token")
        await contacts.refresh(.vps, api: vps); await contacts.refresh(.mac, api: mac)
        XCTAssertEqual(contacts.snapshot(.vps).mainConversation?["preview"].string, "VPS message")
        XCTAssertEqual(contacts.snapshot(.mac).mainConversation?["preview"].string, "MAC message")
        let reopened = ChatBackendContacts(cacheRoot: directory, disk: disk)
        reopened.prepare(.vps, api: vps); reopened.prepare(.mac, api: mac)
        XCTAssertEqual(reopened.snapshot(.vps).profile["agentAvatar"].string, "VPS-avatar")
        XCTAssertEqual(reopened.snapshot(.mac).profile["agentAvatar"].string, "MAC-avatar")
        XCTAssertNotEqual(reopened.snapshot(.vps).scope, reopened.snapshot(.mac).scope)
        XCTAssertEqual(reopened.snapshot(.vps).windows.map(\.title), ["VPS", "VPS project"])
        XCTAssertEqual(reopened.snapshot(.mac).windows.map(\.title), ["MAC", "MAC project"])
        XCTAssertEqual(reopened.snapshot(.vps).windows.last?.conversation?["preview"].string, "VPS second window")
        XCTAssertEqual(reopened.snapshot(.mac).windows.last?.conversation?["preview"].string, "MAC second window")
    }
    func testLateInactiveReadCannotReplaceFreshActiveContacts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SuspendedContactRequests()
        let contacts = ChatBackendContacts(cacheRoot: directory, disk: LocalDocumentDisk(directory: directory), request: { _, path, _ in try await gate.read(path) })
        let api = APIClient(baseURL: "https://mac.fixture", historyURL: "https://mac.fixture/history", token: "fixture")
        let pending = Task { await contacts.refresh(.mac, api: api) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while gate.waits.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.waits.count, 2)
        contacts.capture(.mac, api: api, profile: .object(["agentName": .string("Fresh Mac"), "mainConversationId": .string("fresh-room")]), conversations: [.object(["id": .string("fresh-room")])])
        gate.release(); await pending.value
        XCTAssertEqual(contacts.snapshot(.mac).agentName, "Fresh Mac")
        XCTAssertEqual(contacts.snapshot(.mac).mainID, "fresh-room")
        XCTAssertNil(contacts.snapshot(.mac).error)
    }
    func testUnconfiguredCardDoesNotRequestOrBorrowAnotherBackendsHistory() async {
        var requests = 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = ChatBackendContacts(cacheRoot: directory, disk: LocalDocumentDisk(directory: directory), request: { _, _, _ in requests += 1; return .null })
        let vps = APIClient(baseURL: "https://vps.fixture", historyURL: "https://vps.fixture/history", token: "fixture")
        contacts.capture(.vps, api: vps, profile: .object(["mainConversationId": .string("vps-only")]), conversations: [])
        await contacts.refresh(.mac, api: APIClient(baseURL: "https://mac.fixture", historyURL: "https://mac.fixture/history", token: ""))
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(contacts.snapshot(.mac).configured)
        XCTAssertTrue(contacts.snapshot(.mac).mainID.isEmpty)
        XCTAssertEqual(contacts.snapshot(.vps).mainID, "vps-only")
    }
    func testVisibleHistoryIsNotAttributedToAnotherConnectionDuringSwitch() {
        let chat = ChatSession()
        let vps = APIClient(baseURL: "https://vps.fixture", historyURL: "https://vps.fixture/history", token: "fixture")
        let mac = APIClient(baseURL: "https://mac.fixture", historyURL: "https://mac.fixture/history", token: "fixture")
        chat.configureConnection(api: vps, endpoint: "wss://vps.fixture")
        defer { chat.disconnect() }
        chat.conversations = [.object(["id": .string("vps-room")])]
        XCTAssertEqual(chat.conversations(for: vps).count, 1)
        XCTAssertTrue(chat.conversations(for: mac).isEmpty)
    }
}

final class StickerManagementTests: XCTestCase {
    func testBatchEditsOnlyEnabledFieldsAndCanClearCategoryAndDescription() {
        var edit = StickerBatchEdit()
        XCTAssertFalse(edit.canApply)
        edit.changeCategory = true
        edit.changeDescription = true
        XCTAssertEqual(edit.patch(index: 0), .object(["categoryId": .null, "description": .string("")]))
        edit.rename = true
        XCTAssertFalse(edit.canApply, "An enabled empty name must not rename stickers")
        edit.namePrefix = " Cat "
        edit.changeFavorite = true; edit.favorite = true
        XCTAssertTrue(edit.canApply)
        XCTAssertEqual(edit.patch(index: 1)["name"], .string("Cat 2"))
        XCTAssertEqual(edit.patch(index: 1)["favorite"], .bool(true))
        XCTAssertNil(edit.patch(index: 1).object["url"], "Editing metadata must not rewrite the transparent image")
    }

    func testBatchContinuesAfterFailureAndReportsOnlyConfirmedChanges() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StickerBatchProtocol.self]
        var api = APIClient(baseURL: "https://sticker-batch.example", historyURL: "https://sticker-batch.example", token: "fixture")
        api.requestSession = URLSession(configuration: config)
        let stickers: [JSONValue] = ["first", "failure", "unconfirmed", "last"].map {
            .object(["assetId": .string($0), "name": .string($0)])
        }
        var edit = StickerBatchEdit(); edit.changeCategory = true; edit.categoryID = "cats"
        let updated = await StickerBatchOperation.apply(stickers, edit: edit, delete: false, api: api)
        XCTAssertEqual(updated.succeeded, ["first", "last"])
        XCTAssertEqual(updated.errors.count, 2)
        let deleted = await StickerBatchOperation.apply(stickers, edit: StickerBatchEdit(), delete: true, api: api)
        XCTAssertEqual(deleted.succeeded, ["first", "last"])
        XCTAssertEqual(deleted.errors.count, 2)
    }

    func testBatchCategoryMoveKeepsHyphenatedStickerIDInRequestPath() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StickerBatchProtocol.self]
        var api = APIClient(baseURL: "https://sticker-batch.example", historyURL: "https://sticker-batch.example", token: "fixture")
        api.requestSession = URLSession(configuration: config)
        let id = "3c076946-0197-445c-9d37-c1ab02748e1e"
        let sticker: JSONValue = .object(["assetId": .string(id), "name": .string("Sticker.png")])
        var edit = StickerBatchEdit(); edit.changeCategory = true; edit.categoryID = "cats"
        let result = await StickerBatchOperation.apply([sticker], edit: edit, delete: false, api: api)
        XCTAssertEqual(result.succeeded, [id])
        XCTAssertTrue(result.errors.isEmpty)
    }
}

private final class StickerBatchProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sticker-batch.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.url!.lastPathComponent
        let value: JSONValue
        if id == "failure" { value = .object(["error": .string("Temporary error")]) }
        else if id == "unconfirmed" { value = .object([:]) }
        else if request.httpMethod == "DELETE" { value = .object(["deleted": .bool(true)]) }
        else { value = .object(["sticker": .object(["assetId": .string(id)])]) }
        let response = HTTPURLResponse(url: request.url!, statusCode: id == "failure" ? 400 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class StickerAssetProtocol: URLProtocol {
    static var requestedURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestedURL = request.url
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ChatHistoryPaginationProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var reads = 0
    private static var limits: [String] = []
    static var requestedLimits: [String] { lock.lock(); defer { lock.unlock() }; return limits }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    static func reset() { lock.lock(); reads = 0; limits = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "history-pagination.example"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.reads += 1; Self.limits.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value ?? ""); Self.lock.unlock()
        let earlier = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "before" } == true
        let message: JSONValue = .object([
            "id": .string(earlier ? "older" : "latest"), "role": .string("user"),
            "content": .string("Synthetic pagination fixture"),
            "createdAt": .string(earlier ? "2026-09-01T00:00:00Z" : "2026-10-03T00:00:00Z")
        ])
        let page: JSONValue = .object([
            "conversation": .object(["id": .string("pagination-room")]),
            "messages": .array([message]), "hasMore": .bool(!earlier),
            "before": .string(earlier ? "" : "older-cursor")
        ])
        let data = try! JSONEncoder().encode(page)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SlowRecallProtocol: URLProtocol {
    static var timeout: TimeInterval = 0
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "slow-recall.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.timeout = request.timeoutInterval
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"status":"prepared","deliveryId":"fixture","additionalContext":{}}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

final class ContractTests: XCTestCase {
    @MainActor func testChatIssuesCollectFailuresWithoutLosingOtherDetailsOnDismiss() {
        let chat = ChatSession()
        chat.memoryStatus = "记忆检索超时"
        chat.error = "HTTP 503: Upload failed"
        chat.modelError = "Model list unavailable"
        let record: JSONValue = .object(["id": .string("music-call"), "title": .string("music_playlist_add"),
            "status": .string("failed"), "output": .string("HTTP 403: Catalog lookup rejected")])
        chat.events = ["vesper-tool:" + record.pretty]
        XCTAssertEqual(chat.issueDetails.map(\.id), ["memory", "chat", "models", "tool-music-call"])
        XCTAssertEqual(chat.issueDetails.last?.detail, "HTTP 403: Catalog lookup rejected")
        XCTAssertEqual(chat.issueDetails.first(where: { $0.id == "models" })?.action, .models)
        chat.dismissIssue("memory")
        XCTAssertEqual(chat.issueDetails.map(\.id), ["chat", "models", "tool-music-call"])
        chat.dismissIssue("tool-music-call")
        XCTAssertEqual(chat.issueDetails.map(\.id), ["chat", "models"])
        XCTAssertEqual(ToolActivityRecords.cards(chat.events).first?["output"].string, "HTTP 403: Catalog lookup rejected", "Dismissing a notice must preserve tool history")
        chat.dismissIssue("chat"); chat.dismissIssue("models")
        XCTAssertTrue(chat.issueDetails.isEmpty)
    }

    func testMemoryRecallAllowsResponseSlowerThanOldFourSecondLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowRecallProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var api = APIClient(baseURL: "https://slow-recall.example", historyURL: "", token: "fixture")
        api.requestSession = session
        let result = try await api.request("/api/memory/context", method: "POST", body: .object([:]))
        XCTAssertEqual(SlowRecallProtocol.timeout, 20)
        XCTAssertNoThrow(try ChatMemoryRecall.validate(result))
    }

    func testMemoryRecallDoesNotTreatUnavailableHTTP200AsSuccess() {
        for status in ["unavailable", "host_not_verified", ""] {
            XCTAssertThrowsError(try ChatMemoryRecall.validate(.object(["status": .string(status)])))
        }
        XCTAssertThrowsError(try ChatMemoryRecall.validate(.object(["status": .string("prepared"), "deliveryId": .string("fixture")])))
        for status in ["prepared", "delivered"] {
            XCTAssertNoThrow(try ChatMemoryRecall.validate(.object([
                "status": .string(status), "deliveryId": .string("fixture"), "additionalContext": .object([:])
            ])))
        }
    }

    func testMemoryRecallNoticeDistinguishesTimeoutAndServerFailure() {
        XCTAssertTrue(ChatMemoryRecall.notice(for: URLError(.timedOut)).contains("超时"))
        XCTAssertFalse(ChatMemoryRecall.notice(for: ChatMemoryRecall.Failure.unavailable).contains("超时"))
        XCTAssertTrue(ChatMemoryRecall.notice(for: ChatMemoryRecall.Failure.hostNotVerified).contains("尚未就绪"))
        XCTAssertEqual(ChatMemoryRecall.diagnostic(for: ServiceError(message: "private response", statusCode: 503)), "http-503")
        XCTAssertEqual(ChatMemoryRecall.diagnostic(for: URLError(.timedOut)), "NSURLErrorDomain:-1001")
    }

    private let sleepFixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
    private func sleepSample(_ start: Double, _ end: Double, _ stage: SleepDetails.Stage,
                             source: String = "watch") -> SleepDetails.Sample {
        SleepDetails.Sample(start: sleepFixtureNow.addingTimeInterval(start * 60),
                            end: sleepFixtureNow.addingTimeInterval(end * 60), stage: stage,
                            sourceID: source, sourceName: source)
    }

    func testSleepDetailsDeduplicateSamplesAndIgnoreOverlappingInBedAndUnspecified() {
        let records = [sleepSample(-600, -100, .inBed), sleepSample(-580, -120, .unspecified),
                       sleepSample(-580, -400, .core), sleepSample(-580, -400, .core),
                       sleepSample(-400, -350, .deep), sleepSample(-350, -340, .awake),
                       sleepSample(-340, -240, .rem), sleepSample(-240, -120, .core)]
        // Specific stages win over the overlapping legacy unspecified record.
        let details = SleepDetails.summarize(records, now: sleepFixtureNow)
        XCTAssertEqual(details["totalSleepMinutes"].number, 450)
        XCTAssertEqual(details["stageMinutes"]["core"].number, 300)
        XCTAssertEqual(details["stageMinutes"]["deep"].number, 50)
        XCTAssertEqual(details["stageMinutes"]["rem"].number, 100)
        XCTAssertEqual(details["stageMinutes"]["unspecified"].number, 0)
        XCTAssertEqual(details["stageMinutes"]["awake"].number, 10)
        XCTAssertEqual(details["awakeIntervals"].array.count, 1)
    }

    func testSleepDetailsKeepNightWakingsAndDoNotGuessUnrecordedGaps() {
        let records = [sleepSample(-500, -300, .core), sleepSample(-300, -290, .awake),
                       sleepSample(-290, -285, .awake), sleepSample(-285, -200, .rem),
                       sleepSample(-180, -100, .deep), sleepSample(-100, -90, .awake)]
        let details = SleepDetails.summarize(records, now: sleepFixtureNow, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(details["totalSleepMinutes"].number, 365)
        XCTAssertEqual(details["stageMinutes"]["awake"].number, 15)
        XCTAssertEqual(details["recordedAwakeIntervalCount"].number, 1)
        XCTAssertEqual(details["awakeIntervals"].array.count, 1)
        XCTAssertEqual(details["timeZone"].string, "Asia/Shanghai")
        XCTAssertEqual(details["lastRecordedSleepEnd"].string, ISO8601DateFormatter().string(from: sleepFixtureNow.addingTimeInterval(-100 * 60)))
        XCTAssertEqual(details["stageMinutes"]["unspecified"], .null)
    }

    func testSleepDetailsPreferStageSourceWithoutAddingOtherWriters() {
        let records = [sleepSample(-500, -100, .unspecified, source: "phone"),
                       sleepSample(-480, -300, .core), sleepSample(-300, -120, .rem)]
        let details = SleepDetails.summarize(records, now: sleepFixtureNow)
        XCTAssertEqual(details["source"].string, "watch")
        XCTAssertEqual(details["totalSleepMinutes"].number, 360)
        XCTAssertEqual(details["stageMinutes"]["deep"], .null)
    }

    func testSleepDetailsSelectLatestNapRatherThanAnOlderDetailedNight() {
        let records = [sleepSample(-1200, -800, .core), sleepSample(-100, -60, .unspecified, source: "phone")]
        let details = SleepDetails.summarize(records, now: sleepFixtureNow)
        XCTAssertEqual(details["source"].string, "phone")
        XCTAssertEqual(details["totalSleepMinutes"].number, 40)
        XCTAssertEqual(details["stageMinutes"]["rem"], .null)
        XCTAssertEqual(details["stageMinutes"]["awake"], .null)
        XCTAssertEqual(details["recordedAwakeIntervalCount"], .null)
    }

    func testSleepDetailsConflictsRemainUnspecifiedAndLookbackIsExplicit() {
        let records = [sleepSample(-4500, -4100, .core), sleepSample(-4200, -4000, .deep),
                       sleepSample(5, 10, .rem)]
        let details = SleepDetails.summarize(records, now: sleepFixtureNow)
        XCTAssertTrue(details["windowClipped"].bool)
        XCTAssertEqual(details["totalSleepMinutes"].number, 320)
        XCTAssertEqual(details["conflictingStageMinutes"].number, 100)
        XCTAssertEqual(details["stageMinutes"]["unspecified"].number, 100)
        XCTAssertEqual(details["stageMinutes"]["rem"], .null)
        XCTAssertEqual(SleepDetails.summarize([sleepSample(-100, -50, .inBed)], now: sleepFixtureNow)["status"].string, "no_readable_data")
    }

    @MainActor func testSleepDetailsAreDiscoverableAndAbsentFromUnrequestedSnapshot() {
        XCTAssertTrue(HealthReader.catalog.array.contains { $0["id"].string == "sleep_details" })
        XCTAssertEqual(HealthReader().snapshot["sleepDetails"], .null)
        XCTAssertTrue(NativeDeviceTools.healthTool["description"].string.contains("['sleep_details']"))
        XCTAssertEqual(HealthReader.resolvedMetricIDs(for: ["sleep"]), ["sleep"])
        XCTAssertEqual(HealthReader.resolvedMetricIDs(for: ["sleep_details"]), ["sleep_details"])
        XCTAssertFalse(HealthReader.resolvedMetricIDs(for: ["heart_rate", "steps", "sleep", "wrist_temperature"]).contains("sleep_details"))
    }

    func testAlbumRenameKeepsPhotosAndUnrelatedProfileFields() throws {
        let album: JSONValue = .object(["id": .string("album"), "name": .string("Old name"),
                                       "photoIDs": .array([.string("photo"), .string("chat")])])
        let other: JSONValue = .object(["id": .string("other"), "name": .string("Keep me"), "photoIDs": .array([.string("photo")])])
        let profile: JSONValue = .object(["photoCollections": .array([album, other]),
                                         "agentAvatar": .string("keep-avatar"), "mainConversationId": .string("keep-chat")])
        let renamed = try AlbumPresentation.renameCollection(profile, id: "album", name: "Our moments")
        XCTAssertEqual(renamed["photoCollections"].array[0]["name"].string, "Our moments")
        XCTAssertEqual(renamed["photoCollections"].array[0]["photoIDs"], album["photoIDs"])
        XCTAssertEqual(renamed["photoCollections"].array[1], other)
        XCTAssertEqual(renamed["agentAvatar"], profile["agentAvatar"])
        XCTAssertEqual(renamed["mainConversationId"], profile["mainConversationId"])
        XCTAssertThrowsError(try AlbumPresentation.renameCollection(profile, id: "missing", name: "New"))
    }

    func testAlbumUsesUploadDateAndKeepsCollectionMembershipIndependentOfType() throws {
        let screenshot: JSONValue = .object(["id": .string("chat"), "name": .string("chat-synthetic.jpg"),
            "sourceMessageId": .string("original"), "createdAt": .string("2026-10-03T12:00:00Z"),
            "sourceCreatedAt": .string("2026-09-01T00:00:00Z"), "takenAt": .string("2020-01-01T00:00:00Z"),
            "savedAt": .string("2026-10-03T14:00:00Z")])
        let photo: JSONValue = .object(["id": .string("photo"), "createdAt": .string("2026-10-02T12:00:00.000Z"),
            "savedAt": .string("2026-10-03T15:00:00Z")])
        XCTAssertTrue(AlbumPresentation.isChatScreenshot(screenshot))
        XCTAssertFalse(AlbumPresentation.isChatScreenshot(photo))
        XCTAssertEqual(AlbumPresentation.eventDate(screenshot), AlbumPresentation.date("2026-10-03T12:00:00Z"))
        XCTAssertEqual(AlbumPresentation.sorted([photo, screenshot]).map(\.id), ["chat", "photo"])
        XCTAssertEqual(AlbumPresentation.sorted([photo, screenshot], recent: true).map(\.id), ["photo", "chat"])
        XCTAssertNil(AlbumPresentation.eventDate(.object(["savedAt": .string("2026-10-03T12:00:00Z")])))
        let album: JSONValue = .object(["id": .string("album"), "name": .string("Little moments"), "photoIDs": .array([])])
        var profile: JSONValue = .object(["agentAvatar": .string("keep-avatar"), "mainConversationId": .string("keep-chat"), "photoCollections": .array([album])])
        profile = AlbumPresentation.setMembership(profile, collectionID: "album", photoID: "chat", included: true)
        profile = AlbumPresentation.setMembership(profile, collectionID: "album", photoID: "chat", included: true)
        XCTAssertEqual(profile["photoCollections"].array[0]["photoIDs"].array, [.string("chat")])
        XCTAssertTrue(AlbumPresentation.inCollection(screenshot, collection: profile["photoCollections"].array[0]))
        XCTAssertEqual(profile["agentAvatar"].string, "keep-avatar")
        XCTAssertEqual(profile["mainConversationId"].string, "keep-chat")
        profile = AlbumPresentation.setMembership(profile, collectionID: "album", photoID: "chat", included: false)
        XCTAssertTrue(profile["photoCollections"].array[0]["photoIDs"].array.isEmpty)
    }

    @MainActor func testAlbumGridFitsThreeAndFiveColumnsAndViewerRenders() async throws {
        let photos: [JSONValue] = (0..<15).map { index in .object([
            "id": .string("fixture-\(index)"), "createdAt": .string("2026-10-03T12:00:00Z"),
            "name": .string("chat-fixture.jpg"), "sourceMessageId": .string("fixture"),
            "caption": .string("A synthetic little moment"), "url": .string("")
        ]) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for columns in [3, 5] {
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("相册 · 每行 \(columns) 张").font(.title)
                Text("2026年10月3日").font(.headline)
                AlbumPhotoGrid(photos: photos, columns: columns, open: { _ in })
                Spacer()
            }.padding(12).background(Color.white).foregroundStyle(Color.black)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.width, 393)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Album grid \(columns) columns"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let viewer = AlbumPhotoViewer(photos: photos, initialID: photos[4].id,
                                      removePhoto: { _ in }, membership: { _, _, _ in }).environmentObject(AppStore())
        let host = UIHostingController(rootView: viewer)
        window.rootViewController = host; host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }

    @MainActor func testOpeningChatDoesNotAutomaticallyPrependOlderPages() async throws {
        ChatHistoryPaginationProtocol.reset()
        URLProtocol.registerClass(ChatHistoryPaginationProtocol.self)
        defer { URLProtocol.unregisterClass(ChatHistoryPaginationProtocol.self) }
        let chat = ChatSession()
        chat.configureConnection(api: APIClient(baseURL: "https://history-pagination.example",
                                                historyURL: "https://history-pagination.example", token: "fixture"),
                                 endpoint: "wss://invalid.example", threadID: "")
        let opened = await chat.open(.object(["id": .string("pagination-room")]))
        XCTAssertTrue(opened, chat.error ?? "Opening failed")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestCount, 1)
        XCTAssertEqual(chat.messages.map(\.id), ["latest"])
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestedLimits, ["40"])
        XCTAssertTrue(chat.hasOlderMessages)
        XCTAssertNil(chat.jumpMessageID)

        await chat.loadOlder()
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestCount, 2)
        XCTAssertEqual(chat.messages.map(\.id), ["older", "latest"])
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestedLimits, ["40", "200"])
        let reopened = await chat.open(.object(["id": .string("pagination-room")]))
        XCTAssertTrue(reopened)
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestCount, 2, "Returning to a loaded chat must not fetch the same history again")
        XCTAssertFalse(chat.hasOlderMessages)
        XCTAssertNil(chat.jumpMessageID)
        chat.disconnect()
    }

    func testResumeSnapshotCannotInsertOldMessagesAheadOfPaginatedHistory() {
        let page: [JSONValue] = [
            .object(["id": .string("page-start"), "role": .string("user"), "content": .string("October 16"), "createdAt": .string("2026-10-16T10:00:00Z")]),
            .object(["id": .string("latest"), "role": .string("agent"), "content": .string("Partial"), "createdAt": .string("2026-10-16T10:01:00Z")])
        ]
        let snapshot: JSONValue = .object(["thread": .object(["id": .string("thread"), "turns": .array([
            .object(["id": .string("old-turn"), "status": .string("completed"), "startedAt": .string("2026-10-09T12:00:00Z"), "items": .array([
                .object(["id": .string("old-photo"), "type": .string("userMessage"), "createdAt": .string("2026-10-09T12:00:00Z"), "content": .array([.object(["type": .string("inputText"), "text": .string("Old photo")])])]),
                .object(["id": .string("old-reply"), "type": .string("agentMessage"), "createdAt": .string("2026-10-09T12:01:00Z"), "text": .string("Old reply")])
            ])]),
            .object(["id": .string("current-turn"), "status": .string("completed"), "startedAt": .string("2026-10-16T10:01:00Z"), "items": .array([
                .object(["id": .string("latest"), "type": .string("agentMessage"), "createdAt": .string("2026-10-16T10:01:00Z"), "text": .string("Complete")]),
                .object(["id": .string("new-reply"), "type": .string("agentMessage"), "createdAt": .string("2026-10-16T10:02:00Z"), "text": .string("New reply")])
            ])])
        ])])])
        let recovered = ChatRecovery.merge(page, snapshot: snapshot, conversationID: "room", tombstones: [])
        XCTAssertTrue(recovered.contains { $0.id == "old-photo" }, "The snapshot reproduces the sparse-history bug")
        let visible = ChatTranscript.recoveryWithinLoadedPage(recovered, existing: page, before: "page-start", hasOlder: true)
        XCTAssertEqual(visible.map(\.id), ["page-start", "latest", "new-reply"])
        XCTAssertEqual(visible[1]["content"].string, "Complete")
        XCTAssertEqual(ChatTranscript.recoveryWithinLoadedPage(recovered, existing: page, before: "opaque-page-token", hasOlder: true).map(\.id), visible.map(\.id))
        XCTAssertEqual(ChatTranscript.recoveryWithinLoadedPage(recovered, existing: page, before: "page-start", hasOlder: false).map(\.id), recovered.map(\.id), "A complete history has no page boundary")

        let polluted = [recovered[0]] + page
        XCTAssertEqual(ChatTranscript.recoveryWithinLoadedPage(polluted, existing: polluted,
                                                               before: "page-start", hasOlder: true).map(\.id),
                       page.map(\.id), "A reconnect must remove old snapshot rows already cached above the page")
        var oldPending = recovered[0]
        oldPending["status"] = .string("pending")
        XCTAssertEqual(ChatTranscript.recoveryWithinLoadedPage([oldPending] + page, existing: page,
                                                               before: "page-start", hasOlder: true).map(\.id),
                       page.map(\.id), "An old pending outbox row must not bypass the current page boundary")
    }

    func testScreenshotDeliveryPreservesOriginalSource() {
        let result: JSONValue = .object(["attachments": .array([.object(["key": .string("screenshot.jpg"), "type": .string("image/jpeg"), "sourceConversationId": .string("original-chat"), "sourceMessageId": .string("original-message")])])])
        let delivered = ChatFileDelivery.message(result, conversationID: "current-chat", threadID: "t", turnID: "turn", callID: "capture", createdAt: "now")
        XCTAssertEqual(delivered["conversationId"].string, "current-chat")
        XCTAssertEqual(delivered["metadata"]["attachments"].array.first?["sourceConversationId"].string, "original-chat")
        XCTAssertEqual(delivered["metadata"]["attachments"].array.first?["sourceMessageId"].string, "original-message")
    }

    func testChatTerminalIncludesRealExecutionAndFileChangesButExcludesOrdinaryTools() {
        func record(_ id: String, _ type: String) -> JSONValue {
            .object(["id": .string(id), "role": .string("system"),
                     "metadata": .object(["execution": .object(["type": .string(type), "output": .string("output")])])])
        }
        let input = [record("command", "commandExecution"), record("search", "webSearch"),
                     record("patch", "fileChange"), record("shell", "shellCall")]
        XCTAssertEqual(ChatTerminalRecords.entries(input).map(\.id), ["command", "patch", "shell"])
        var streaming = input[0]
        streaming["metadata"]["execution"]["output"] = .string("updated output")
        XCTAssertEqual(ChatTerminalRecords.entries([streaming])[0]["metadata"]["execution"]["output"].string, "updated output")
    }

    func testOldMessagePhaseBackfillMatchesOriginalIdentityWithoutChangingBodyOrTime() {
        let saved: JSONValue = .object(["id": .string("saved"), "role": .string("agent"), "content": .string("original body"), "createdAt": .string("2026-09-30T07:21:20Z"), "metadata": .object(["itemId": .string("item"), "threadId": .string("thread")])])
        let entry: JSONValue = .object(["turnId": .string("turn"), "item": .object(["id": .string("item"), "type": .string("agentMessage"), "phase": .string("commentary"), "text": .string("different server body")])])
        let restored = ChatPhaseRecovery.restore([saved], entries: [entry], threadID: "thread", fallbackThreadID: nil, tombstones: [])
        XCTAssertEqual(restored[0]["content"], saved["content"])
        XCTAssertEqual(restored[0]["createdAt"], saved["createdAt"])
        XCTAssertEqual(restored[0]["metadata"]["phase"].string, "commentary")
        XCTAssertEqual(restored[0]["metadata"]["turnId"].string, "turn")
        XCTAssertTrue(ChatPresentation.isActivity(restored[0]))
        XCTAssertEqual(ChatPhaseRecovery.restore(restored, entries: [entry], threadID: "thread", fallbackThreadID: nil, tombstones: []), restored)
        XCTAssertEqual(ChatPhaseRecovery.restore([saved], entries: [entry], threadID: "other", fallbackThreadID: nil, tombstones: []), [saved])
        XCTAssertEqual(ChatPhaseRecovery.restore([saved], entries: [entry], threadID: "thread", fallbackThreadID: nil, tombstones: [.object(["itemId": .string("item")])]), [saved])
        XCTAssertTrue(ChatPhaseRecovery.restore([], entries: [entry], threadID: "thread", fallbackThreadID: nil, tombstones: []).isEmpty)
        var unknown = entry; unknown["item"]["phase"] = .null
        XCTAssertEqual(ChatPhaseRecovery.restore([saved], entries: [unknown], threadID: "thread", fallbackThreadID: nil, tombstones: []), [saved])
    }

    private func sharedReply(_ id: String, media: String? = nil, caption: String = "", status: String = "delivered") -> JSONValue {
        var value: JSONValue = .object(["id": .string(id), "conversationId": .string("room"), "role": .string("agent"), "content": .string(caption), "status": .string(status), "metadata": .object(["turnId": .string("turn"), "threadId": .string("thread")])])
        if let media {
            if media == "attachments" { value["metadata"][media] = .array([.object(["id": .string(id + "-file"), "type": .string("image/png"), "url": .string("https://example.com/photo.png")])]) }
            else { value["metadata"][media] = .object(["id": .string(id + "-media"), "assetId": .string(id + "-asset")]) }
            value["metadata"]["showTurnStatus"] = .bool(false)
        }
        return value
    }

    func testAssistantMediaAndCaptionShareOneRowInEitherArrivalOrder() {
        for kind in ["sticker", "attachments", "musicCard", "locationCard"] {
            let media = sharedReply("media", media: kind)
            let text = sharedReply("text", caption: "For you", status: "streaming")
            for input in [[media, text], [text, media]] {
                let rows = ChatPresentation.displayRows(input)
                XCTAssertEqual(rows.count, 1, kind)
                XCTAssertEqual(rows[0].id, "text")
                XCTAssertEqual(rows[0].messages, input, "Keep the originals for deletion and memory")
                XCTAssertEqual(rows[0].presentedMessage["content"].string, "For you")
                XCTAssertEqual(rows[0].presentedMessage["status"].string, "streaming")
                XCTAssertEqual(rows[0].presentedMessage["metadata"]["sharedMedia"].array, [media])
                XCTAssertEqual(ChatPresentation.liveHeadingID(rows, turnID: "turn"), "text")
                XCTAssertEqual(ChatPresentationSnapshot(input).lastReplyID, "text")
                XCTAssertEqual(ChatPresentationSnapshot(input).rowID(forMessageID: "media"), "text")
                XCTAssertEqual(ChatPresentationSnapshot(input).rowID(forMessageID: "text"), "text")
            }
        }
    }

    func testAssistantMixedMediaRetainsCaptionsAndActivityOnce() {
        var photo = sharedReply("photo", media: "attachments", caption: "文件")
        photo["metadata"]["attachmentOnly"] = .bool(true)
        let music = sharedReply("music", media: "musicCard", caption: "Listen with me")
        let sticker = sharedReply("sticker", media: "sticker")
        var activity = sharedReply("tool")
        activity["role"] = .string("tool")
        let text = sharedReply("text", caption: "A little thought")
        let input = [photo, activity, music, sticker, text]
        let rows = ChatPresentation.displayRows(input)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].messages, [photo, music, sticker, text])
        XCTAssertEqual(rows[0].activities, [activity])
        XCTAssertEqual(rows[0].presentedMessage["content"].string, "Listen with me\n\nA little thought")
        XCTAssertEqual(rows[0].presentedMessage["metadata"]["attachments"].array, photo["metadata"]["attachments"].array)
        XCTAssertEqual(photo["content"].string, "文件")
        XCTAssertEqual(rows[0].presentedMessage["metadata"]["attachmentOnly"], .bool(false))
    }

    func testWholeAssistantTurnSharesTimestampIncludingLegacyVoiceAndMultipleTexts() {
        var voice = sharedReply("voice:thread:call", media: "attachments")
        voice["metadata"]["voiceMessage"] = .bool(true)
        voice["createdAt"] = .string("2026-10-07T05:31:30Z")
        var first = sharedReply("first", caption: "语音发过去了。")
        first["createdAt"] = .string("2026-10-07T05:31:40Z")
        var second = sharedReply("second", caption: "点开就能听见。")
        second["createdAt"] = .string("2026-10-07T05:31:41Z")
        var tool = sharedReply("tool"); tool["role"] = .string("tool")
        for legacy in [false, true] {
            var recording = voice
            if legacy {
                recording["metadata"]["turnId"] = .null
                recording["metadata"]["threadId"] = .null
            }
            let rows = ChatPresentation.displayRows([recording, tool, first, second])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].messages.map(\.id), [recording.id, first.id, second.id])
            XCTAssertEqual(rows[0].presentedMessage["createdAt"], voice["createdAt"])
            XCTAssertEqual(rows[0].activities.map(\.id), [tool.id])
            XCTAssertEqual(ChatPresentation.liveHeadingID(rows, turnID: "turn"), rows[0].id)
        }
        XCTAssertEqual(ChatPresentation.displayRows([first, second]).count, 1)
        XCTAssertEqual(ChatPresentation.liveHeadingID(ChatPresentation.displayRows([voice]), turnID: "turn"), voice.id)
        var unknownVoice = voice
        unknownVoice["metadata"]["turnId"] = .null
        unknownVoice["metadata"]["threadId"] = .null
        unknownVoice["id"] = .string("voice:other-thread:call")
        XCTAssertEqual(ChatPresentation.displayRows([unknownVoice, first]).count, 2)
    }

    func testCallCardSharesItsInvitingTurnButNotUserOrUnrelatedCalls() {
        var call = sharedReply("call-record", caption: "Voice call · 0:01")
        call["createdAt"] = .string("2026-10-07T05:36:52Z")
        call["metadata"]["call"] = .object(["initiator": .string("agent"), "startedAt": .string("2026-10-07T05:36:51Z")])
        var reply = sharedReply("reply", caption: "邀请已经弹出来了。")
        reply["createdAt"] = .string("2026-10-07T05:36:56Z")
        let rows = ChatPresentation.displayRows([call, reply])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].messages, [call, reply])
        XCTAssertEqual(rows[0].presentedMessage["content"], reply["content"])
        XCTAssertEqual(ChatPresentation.liveHeadingID(rows, turnID: "turn"), rows[0].id)
        var legacy = call; legacy["metadata"]["turnId"] = .null; legacy["metadata"]["threadId"] = .null
        XCTAssertEqual(ChatPresentation.displayRows([legacy, reply]).count, 1)
        legacy["metadata"]["call"]["startedAt"] = .string("2026-10-06T05:36:51Z")
        XCTAssertEqual(ChatPresentation.displayRows([legacy, reply]).count, 2)
        var user = call; user["role"] = .string("user"); user["metadata"]["call"]["initiator"] = .string("user")
        XCTAssertEqual(ChatPresentation.displayRows([user, reply]).count, 2)
        var other = call; other["metadata"]["turnId"] = .string("other")
        XCTAssertEqual(ChatPresentation.displayRows([other, reply]).count, 2)
    }

    func testCallDialogueStaysInCallCardInsteadOfChatBody() {
        let spoken: JSONValue = .object(["id": .string("spoken"), "conversationId": .string("room"), "role": .string("user"), "content": .string("Are you there?"), "metadata": .object(["callOnly": .bool(true), "threadId": .string("thread"), "turnId": .string("call-turn")])])
        let answer: JSONValue = .object(["id": .string("answer"), "conversationId": .string("room"), "role": .string("agent"), "content": .string("I am here."), "metadata": .object(["callOnly": .bool(true), "threadId": .string("thread"), "turnId": .string("call-turn")])])
        let callTool: JSONValue = .object(["id": .string("tool"), "conversationId": .string("room"), "role": .string("tool"), "content": .string("Internal call step"), "metadata": .object(["threadId": .string("thread"), "turnId": .string("call-turn")])])
        let card: JSONValue = .object(["id": .string("call-card"), "role": .string("user"), "content": .string("Voice call ended · 0:42"), "metadata": .object(["call": .object(["transcript": .array([spoken, answer])])])])
        XCTAssertEqual(ChatPresentation.displayRows([spoken, callTool, answer, card]).map(\.id), ["call-card"])
        XCTAssertEqual(card["metadata"]["call"]["transcript"].array.count, 2)

        var sameTurnCard = card
        sameTurnCard["conversationId"] = .string("room")
        sameTurnCard["metadata"]["threadId"] = .string("thread")
        sameTurnCard["metadata"]["turnId"] = .string("call-turn")
        XCTAssertEqual(ChatPresentation.displayRows([spoken, callTool, answer, sameTurnCard]).map(\.id), ["call-card"])
    }

    func testAutomaticCallPromptIsNotShownAsUserSpeech() {
        let prompt: JSONValue = .object(["id": .string("prompt"), "role": .string("user"), "content": .string("automatic"), "metadata": .object(["internalCallPrompt": .bool(true)])])
        XCTAssertTrue(ChatScreenContext.isHidden(prompt))
        var actualSpeech = prompt
        actualSpeech["metadata"]["internalCallPrompt"] = .bool(false)
        XCTAssertFalse(ChatScreenContext.isHidden(actualSpeech))
    }

    func testAssistantMediaGroupingRespectsConversationTurnAndMessageBoundaries() {
        let media = sharedReply("media", media: "sticker")
        let text = sharedReply("text", caption: "Hello")
        for field in ["turnId", "threadId"] {
            for value in ["", "other"] {
                var different = text; different["metadata"][field] = .string(value)
                XCTAssertEqual(ChatPresentation.displayRows([media, different]).count, 2)
            }
        }
        var other = text; other["conversationId"] = .string("other")
        XCTAssertEqual(ChatPresentation.displayRows([media, other]).count, 2)
        var wake = text; wake["metadata"]["wakeRunId"] = .string("wake")
        XCTAssertEqual(ChatPresentation.displayRows([media, wake]).count, 2)
        var user = text; user["role"] = .string("user")
        XCTAssertEqual(ChatPresentation.displayRows([media, user, text]).count, 3)
        var voice = media; voice["metadata"]["voiceMessage"] = .bool(true)
        XCTAssertEqual(ChatPresentation.displayRows([voice, text]).count, 1)
        var second = text; second["id"] = .string("second")
        XCTAssertEqual(ChatPresentation.displayRows([media, text, second]).count, 1)
        var question = sharedReply("question"); question["role"] = .string("tool"); question["metadata"]["userInput"] = .object(["status": .string("pending")])
        XCTAssertEqual(ChatPresentation.displayRows([media, question, text]).count, 2)
        var userMedia = media; userMedia["role"] = .string("user"); userMedia["content"] = .string("My caption")
        let row = ChatPresentation.displayRows([userMedia])[0]
        XCTAssertEqual(row.presentedMessage, userMedia)
    }

    func testCommentaryIsCollapsedIntoMatchingReplyWithoutHidingFinalText() {
        let commentary: JSONValue = .object(["id": .string("progress"), "role": .string("agent"), "content": .string("Checking books"), "metadata": .object(["phase": .string("commentary"), "turnId": .string("t")])])
        let reply: JSONValue = .object(["id": .string("final"), "role": .string("agent"), "content": .string("Read this book"), "metadata": .object(["phase": .string("final_answer"), "turnId": .string("t")])])
        let rows = ChatPresentation.displayRows([commentary, reply])
        XCTAssertEqual(rows.map(\.id), ["final"])
        XCTAssertEqual(rows.first?.activities.map(\.id), ["progress"])
        var legacy = commentary
        legacy["metadata"]["phase"] = .null
        XCTAssertFalse(ChatPresentation.isActivity(legacy), "Never guess a phase from message wording")
        XCTAssertTrue(ChatPresentation.displayRows([commentary]).first?.activity == true)
    }

    func testRecoveredServerPhaseSurvivesReload() {
        let saved: JSONValue = .object(["id": .string("p"), "role": .string("agent"), "content": .string("Checking")])
        let snapshot: JSONValue = .object(["thread": .object(["id": .string("thread"), "turns": .array([
            .object(["id": .string("turn"), "status": .string("completed"), "items": .array([
                .object(["id": .string("p"), "type": .string("agentMessage"), "text": .string("Checking"), "phase": .string("commentary")])
            ])])
        ])])])
        let restored = ChatRecovery.merge([saved], snapshot: snapshot, conversationID: "room", tombstones: [])
        XCTAssertEqual(restored.first?["metadata"]["phase"].string, "commentary")
        XCTAssertTrue(ChatPresentation.isActivity(restored[0]))
    }

    func testWakeContextIncludesOnlyThisRoomsExternalRepliesAndRespectsDeletion() {
        let wake: JSONValue = .object(["id": .string("wake:run:final"), "conversationId": .string("room"), "role": .string("agent"), "content": .string("We should read Frankenstein"), "createdAt": .string("2026-09-30T07:00:00Z"), "metadata": .object(["wakeRunId": .string("run"), "threadId": .string("wake-thread"), "showTurnStatus": .bool(false)])])
        var other = wake; other["conversationId"] = .string("other"); other["content"] = .string("PRIVATE OTHER ROOM")
        var tool = wake; tool["role"] = .string("tool"); tool["content"] = .string("TOOL OUTPUT")
        let context = ChatTranscript.wakeContext([wake, other, tool], conversationID: "room", threadID: "chat-thread")
        XCTAssertTrue(context.contains("Frankenstein"))
        XCTAssertFalse(context.contains("PRIVATE OTHER ROOM"))
        XCTAssertFalse(context.contains("TOOL OUTPUT"))
        XCTAssertEqual(ChatTranscript.wakeContext([wake], conversationID: "room", threadID: "wake-thread"), "")
        let deleted = ChatTranscript.merge([wake], incoming: [], tombstones: [.object(["messageId": .string(wake.id)])])
        XCTAssertEqual(ChatTranscript.wakeContext(deleted, conversationID: "room", threadID: "chat-thread"), "")
        XCTAssertEqual(ChatTranscript.timestamp(wake), "2026-09-30T07:00:00Z")
        var late = wake; late["metadata"]["wake"] = .object(["completedAt": .string("2026-09-30T06:55:00Z")])
        XCTAssertEqual(ChatTranscript.timestamp(late), "2026-09-30T06:55:00Z")
    }

    func testStickerFetchesOnlyOurAssetAndSendsInlineImage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StickerAssetProtocol.self]
        var api = APIClient(baseURL: "https://vesper.example", historyURL: "https://history.example", token: "test")
        api.stickerSession = URLSession(configuration: config)
        let id = "aaad7a49-9441-4ce4-b619-f160138608ee"
        let input = try await api.stickerInputURL(assetID: id)
        XCTAssertEqual(StickerAssetProtocol.requestedURL?.absoluteString, "https://vesper.example/api/stickers/assets/" + id)
        XCTAssertTrue(input.hasPrefix("data:image/png;base64,"))
        let data = try XCTUnwrap(Data(base64Encoded: String(input.dropFirst("data:image/png;base64,".count))))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var pixels = [UInt8](repeating: 0, count: 16)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        XCTAssertEqual(pixels[3], 255, "The sticker subject stays opaque")
        XCTAssertEqual(pixels[7], 0, "Sending must not fill transparent pixels with white")
        do {
            _ = try await api.stickerInputURL(assetID: "https://somewhere-else.example/image.jpg")
            XCTFail("An external URL must not be loaded as a sticker")
        } catch { XCTAssertEqual(StickerAssetProtocol.requestedURL?.absoluteString, "https://vesper.example/api/stickers/assets/" + id) }
    }

    func testTranscriptKeepsFullChronologicalHistoryAcrossPagesAndReconnect() {
        func row(_ id: String, _ time: String) -> JSONValue {
            .object(["id": .string(id), "role": .string("user"), "createdAt": .string(time)])
        }
        let latest = [row("today", "2026-09-26T20:02:00Z"), row("yesterday", "2026-09-25T19:00:00Z")]
        let old = [row("first", "2026-09-21T02:05:42Z"), row("second", "2026-09-22T23:59:00Z")]
        let afterPage = ChatTranscript.merge(latest, incoming: old, tombstones: [])
        XCTAssertEqual(afterPage.map(\.id), ["first", "second", "yesterday", "today"])
        let afterReconnect = ChatTranscript.merge(afterPage, incoming: latest + old, tombstones: [])
        XCTAssertEqual(afterReconnect.map(\.id), afterPage.map(\.id))
        XCTAssertEqual(ChatPresentation.displayRows(afterReconnect).map(\.id), afterPage.map(\.id))
    }
    func testTranscriptOnlyDeliveredReceiptReplacesPendingAndTombstonesWin() {
        let pending: JSONValue = .object(["id": .string("send"), "status": .string("pending"), "content": .string("original")])
        let uncertain: JSONValue = .object(["id": .string("send"), "status": .string("sending"), "content": .string("other")])
        let delivered: JSONValue = .object(["id": .string("send"), "status": .string("delivered"), "content": .string("stored")])
        XCTAssertEqual(ChatTranscript.merge([pending], incoming: [uncertain], tombstones: []), [pending])
        XCTAssertEqual(ChatTranscript.merge([pending], incoming: [delivered], tombstones: []), [delivered])
        XCTAssertTrue(ChatTranscript.merge([pending], incoming: [delivered], tombstones: [.object(["messageId": .string("send")])]).isEmpty)
    }
    func testTranscriptDoesNotInventDatesForUnsyncedMessages() {
        func row(_ id: String, _ time: String) -> JSONValue {
            .object(["id": .string(id), "createdAt": .string(time)])
        }
        let input = [row("late", "2026-09-26T10:00:00Z"), row("pending", ""),
                     row("early", "2026-09-21T10:00:00Z")]
        XCTAssertEqual(ChatTranscript.ordered(input).map(\.id), ["early", "pending", "late"])
    }
    @MainActor func testResumeRequestsMetadataWithoutLargeThreadTurns() async throws {
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000)
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"), endpoint: "wss://invalid.example", threadID: "thread")
        defer { chat.disconnect() }
        try await chat.connect()
        let resume = try XCTUnwrap(socket.packets.first { $0["method"].string == "thread/resume" })
        XCTAssertEqual(resume["params"]["excludeTurns"], .bool(true))
        XCTAssertEqual(chat.connectionStage, .ready)
    }
    @MainActor func testLiveChatSocketRaisesReceiveLimitAboveObservedSnapshot() {
        let socket = ChatSession.liveSocket(URL(string: "wss://example.invalid/chat")!)
        XCTAssertEqual(socket.maximumMessageSize, 16 * 1024 * 1024)
        XCTAssertGreaterThan(socket.maximumMessageSize, 1_271_125)
        let diagnostic = ChatSession.connectionDiagnostic(stage: .resume,
            failure: NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE)), httpStatus: nil, closeCode: 0)
        XCTAssertTrue(diagnostic.contains("16 MB"))
        socket.cancel(with: .goingAway, reason: nil)
    }
    @MainActor func testHistoryRecordMustMatchBeforeSwitchingChat() throws {
        XCTAssertThrowsError(try ChatSession.validateHistoryRecord(.object(["conversation": .null]), expectedID: "wanted"))
        XCTAssertThrowsError(try ChatSession.validateHistoryRecord(.object(["conversation": .object(["id": .string("other")])]), expectedID: "wanted"))
        XCTAssertNoThrow(try ChatSession.validateHistoryRecord(.object(["conversation": .object(["id": .string("wanted")])]), expectedID: "wanted"))
        XCTAssertNoThrow(try ChatSession.validateHistoryRecord(.object(["conversation": .object(["vesperConversationId": .string("wanted")])]), expectedID: "wanted"))
    }

    @MainActor func testUnplayableSelectionDoesNotLeavePreviousSongMetadata() {
        let player = MusicPlayer()
        let first: JSONValue = .object(["id": .string("first"), "title": .string("First")])
        let second: JSONValue = .object(["id": .string("second"), "title": .string("Second"), "url": .string("http://invalid.example/audio")])
        player.setQueue([first, second])
        player.start(second)
        XCTAssertEqual(player.track.id, "second")
        XCTAssertFalse(player.playing)
        XCTAssertEqual(player.position, 0)
        XCTAssertNotNil(player.error)
        player.pause()
        XCTAssertFalse(player.playing)
        player.remove("second")
        XCTAssertEqual(player.track.id, "first")
    }
    @MainActor func testPlaybackContextUsesCurrentSelectionWithoutClaimingAudio() {
        let player = MusicPlayer()
        player.start(.object(["id": .string("new"), "title": .string("我们俩"), "artist": .string("郭顶")]))
        let context = player.liveContext
        XCTAssertEqual(context["track"]["title"].string, "我们俩")
        XCTAssertEqual(context["playing"], .bool(false))
        XCTAssertEqual(context["audioIncluded"], .bool(false))
        XCTAssertFalse(context["observedAt"].string.isEmpty)
    }
    func testWidgetSnapshotPreservesUnknownUsageAsMissing() throws {
        let snapshot = WidgetSnapshot(updatedAt: Date(timeIntervalSince1970: 100), text: "Note", values: [:])
        let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(restored.values["remaining"])
        XCTAssertEqual(restored.updatedAt, snapshot.updatedAt)
        XCTAssertEqual(restored.text, "Note")
    }

    func testToolCardsExcludeLifecycleAndPreserveRepeatedFailures() {
        let cards = ToolActivityRecords.cards(["userMessage · running", "dynamicToolCall · completed", "request_native_call · failed\nCallKit code 0", "request_native_call · failed\nSecond attempt"])
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0]["title"].string, "request_native_call")
        XCTAssertEqual(cards[0]["status"].string, "failed")
        XCTAssertEqual(cards[0]["output"].string, "CallKit code 0")
        XCTAssertNotEqual(cards[0].id, cards[1].id)
        let record: JSONValue = .object(["id": .string("call1"), "title": .string("request_native_call"), "status": .string("failed"), "durationMs": .number(200)])
        XCTAssertEqual(ToolActivityRecords.cards(["request_native_call · failed", "vesper-tool:" + record.pretty]), [record])
    }
    func testToolCardsUpdateRunningRowWithCompletion() {
        let cards = ToolActivityRecords.cards([
            "webSearch · running", "contextCompaction · running",
            "webSearch · completed", "contextCompaction · completed",
            "webSearch · running", "webSearch · failed\nTimed out"
        ])
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.map { $0["title"].string }, ["webSearch", "contextCompaction", "webSearch"])
        XCTAssertEqual(cards.map { $0["status"].string }, ["completed", "completed", "failed"])
        XCTAssertEqual(cards[2]["output"].string, "Timed out")
        let native: JSONValue = .object(["id": .string("native-1"), "title": .string("read_native_context"), "status": .string("completed")])
        let mixed = ToolActivityRecords.cards(["webSearch · running", "vesper-tool:" + native.pretty,
                                               "read_native_context · completed", "webSearch · completed"])
        XCTAssertEqual(mixed.map { $0["title"].string }, ["webSearch", "read_native_context"])
        XCTAssertEqual(mixed[0]["status"].string, "completed")
    }
    func testMcpToolCardsShowConnectionAndActualTool() {
        let arguments: JSONValue = .object(["connectionId": .string("forum-id"), "toolName": .string("search_posts")])
        let title = MCPToolLabels.title(name: "call_configured_mcp_tool", arguments: arguments,
                                        connectionNames: ["forum-id": "Community"])
        XCTAssertEqual(title, "MCP: Community / search_posts")
        XCTAssertEqual(MCPToolLabels.title(name: "list_configured_mcp_tools", arguments: .object([:])), "MCP: List available tools")
        let record: JSONValue = .object(["id": .string("mcp-1"), "title": .string(title),
                                         "rawName": .string("call_configured_mcp_tool"), "status": .string("completed")])
        let cards = ToolActivityRecords.cards(["vesper-tool:" + record.pretty, "call_configured_mcp_tool · completed"])
        XCTAssertEqual(cards, [record], "The wrapper completion must not create a second generic row")
        let direct: JSONValue = .object(["server": .string("zlib"), "tool": .string("search")])
        XCTAssertEqual(MCPToolLabels.directTitle(direct), "MCP: zlib / search")
        XCTAssertEqual(MCPToolLabels.directTitle(.object(["tool": .string("mcp__codex_apps__search_books")])),
                       "MCP: codex_apps / search_books")
    }
    func testHistoryRestoresPublicDetailsWithoutResurrectingMessages() throws {
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"thread","turns":[{"id":"turn","items":[{"type":"reasoning","summary":["Saved summary"],"content":["Never display raw reasoning"]},{"type":"dynamicToolCall","tool":"sticker_search","status":"completed"},{"id":"reply","type":"agentMessage","text":"Hello"},{"id":"deleted","type":"agentMessage","text":"Deleted"}]}]}}"#.utf8))
        let saved: JSONValue = .object(["id": .string("reply"), "role": .string("agent"), "content": .string("Hello")])
        let restored = ChatDetailRecovery.restore([saved], snapshot: snapshot)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0]["metadata"]["thoughtSummary"].string, "Saved summary")
        XCTAssertEqual(restored[0]["metadata"]["toolEvents"].array.map { $0.string }, ["sticker_search · completed"])
        XCTAssertEqual(restored[0]["metadata"]["turnId"].string, "turn")
        XCTAssertEqual(ChatDetailRecovery.restore(restored, snapshot: snapshot), restored)
        XCTAssertEqual(ChatDetailRecovery.restore(restored, snapshot: .object([:])), restored)
        XCTAssertTrue(ChatDetailRecovery.restore([], snapshot: snapshot).isEmpty)
    }
    func testWakeLedgerIsHiddenButMessagesAndNormalToolsRemain() {
        let activity: JSONValue = .object(["id": .string("wake-tool"), "role": .string("system"), "metadata": .object(["wakeRunId": .string("run"), "blockType": .string("execution")])])
        let reply: JSONValue = .object(["id": .string("wake-final"), "role": .string("agent"), "content": .string("Hello"), "metadata": .object(["wakeRunId": .string("run"), "blockType": .string("agentMessage")])])
        let normal: JSONValue = .object(["id": .string("normal-tool"), "role": .string("tool")])
        XCTAssertTrue(ChatPresentation.isWakeActivity(activity))
        XCTAssertFalse(ChatPresentation.isWakeActivity(reply))
        XCTAssertFalse(ChatPresentation.isWakeActivity(normal))
        let rows = ChatPresentation.displayRows([activity, reply])
        XCTAssertEqual(rows.map { $0.id }, ["wake-final"])
        XCTAssertTrue(rows[0].activities.isEmpty)
    }
    func testLateImportedWakeReplyUsesItsOriginalCompletionTime() {
        let before: JSONValue = .object(["id": .string("before"), "role": .string("user"), "createdAt": .string("2026-09-28T12:00:00Z")])
        let after: JSONValue = .object(["id": .string("after"), "role": .string("user"), "createdAt": .string("2026-09-28T12:10:00Z")])
        let wake: JSONValue = .object(["id": .string("wake"), "role": .string("agent"), "createdAt": .string("2026-09-28T12:20:00Z"), "metadata": .object(["wakeRunId": .string("run"), "wake": .object(["completedAt": .string("2026-09-28T12:05:00Z")])])])
        XCTAssertEqual(ChatPresentation.displayRows([before, after, wake]).map(\.id), ["before", "wake", "after"])
        XCTAssertEqual(ChatTranscript.merge([before, after], incoming: [wake], tombstones: []).map(\.id), ["before", "wake", "after"])
        let legacy: JSONValue = .object(["id": .string("wake:auto-1790597100:final"), "role": .string("agent"), "createdAt": .string("2026-09-28T12:20:00Z"), "metadata": .object(["wakeRunId": .string("auto-1790597100"), "source": .string("automation")])])
        XCTAssertEqual(ChatPresentation.displayRows([before, after, legacy]).map(\.id), ["before", "after", "wake:auto-1790597100:final"])
    }
    func testDelayedWakeRemainsLatestAcrossPagingAndThreadResume() {
        let previous: JSONValue = .object(["id": .string("previous"), "role": .string("agent"), "createdAt": .string("2026-09-28T23:48:46Z")])
        let wake: JSONValue = .object(["id": .string("wake:auto-1790626323:final"), "role": .string("agent"), "status": .string("delivered"), "createdAt": .string("2026-09-29T01:51:59.018971Z"), "metadata": .object(["source": .string("automation"), "wakeRunId": .string("auto-1790626323"), "blockType": .string("agentMessage"), "startedAt": .number(1790646692), "showTurnStatus": .bool(false)])])
        let earlier: JSONValue = .object(["id": .string("earlier"), "role": .string("user"), "createdAt": .string("2026-09-28T20:00:00Z")])
        let paged = ChatTranscript.merge([previous, wake], incoming: [earlier], tombstones: [])
        let resumed = ChatRecovery.merge(paged, snapshot: .object(["thread": .object(["id": .string("main-thread"), "turns": .array([])])]), conversationID: "room", tombstones: [])
        XCTAssertEqual(ChatPresentation.displayRows(resumed).map(\.id), ["earlier", "previous", wake.id])
        XCTAssertEqual(resumed.last, wake)
        var undated = wake; undated["createdAt"] = .null; undated["metadata"]["startedAt"] = .null
        XCTAssertEqual(ChatTranscript.ordered([previous, undated, earlier]).map(\.id), ["earlier", wake.id, "previous"], "A job ID alone must not invent a message date")
    }
    func testMixedToolCatalogUsesOneCanonicalFormat() throws {
        let legacy: JSONValue = .object(["name": .string("native_health"), "description": .string("Read"), "inputSchema": .object(["type": .string("object")])])
        var canonical = legacy; canonical["type"] = .string("function"); canonical["name"] = .string("server_tool")
        let result = try NativeToolCatalog.normalize([canonical, legacy])
        XCTAssertEqual(result.map { $0["type"].string }, ["function", "function"])
        XCTAssertEqual(result.map { $0["name"].string }, ["server_tool", "native_health"])
        XCTAssertEqual(result[1]["inputSchema"], legacy["inputSchema"])
        XCTAssertThrowsError(try NativeToolCatalog.normalize([.object(["name": .string("broken")])]))
    }
    func testMiniMaxFullEndpointIsNotAppendedTwice() {
        let config: JSONValue = .object(["provider": .string("MiniMax"), "baseUrl": .string("https://api.minimax.chat/v1/t2a_v2"), "groupId": .string("group")])
        let result = VoiceConfiguration.normalized(config)
        XCTAssertEqual(result["baseUrl"].string, "https://api.minimax.chat")
        XCTAssertEqual(result["endpoint"].string, "https://api.minimax.chat/v1/t2a_v2?GroupId=group")
        XCTAssertEqual(VoiceConfiguration.normalized(result), result)
        var root = config; root["baseUrl"] = .string("https://api.minimax.io")
        XCTAssertEqual(VoiceConfiguration.normalized(root), root)
    }
    func testDateCountersRepeatAndIncludeToday() throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let now = try XCTUnwrap(f.date(from: "2026-09-14"))
        var item: JSONValue = .object(["date": .string("2026-08-09")])
        XCTAssertEqual(DateCounter.days(item, now: now), -36)
        XCTAssertEqual(DateCounter.count(item, now: now), 36)
        item["includeToday"] = .bool(true)
        XCTAssertEqual(DateCounter.count(item, now: now), 37)
        item["date"] = .string("2020-10-29"); item["repeatRule"] = .string("yearly"); item["includeToday"] = .bool(false)
        XCTAssertEqual(DateCounter.days(item, now: now), 45)
        item["date"] = .string("2020-09-14")
        XCTAssertEqual(DateCounter.days(item, now: now), 0)
        item["date"] = .string("not-a-date")
        XCTAssertNil(DateCounter.days(item, now: now))
    }
    @MainActor func testEffortsFollowSelectedModelCatalog() {
        let chat = ChatSession()
        chat.models = [.object(["model": .string("a"), "defaultReasoningEffort": .string("medium"), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("low")]), .object(["reasoningEffort": .string("medium")])])]), .object(["model": .string("b"), "supportedReasoningEfforts": .array([])])]
        chat.selectModel("a"); XCTAssertEqual(chat.effort, "medium")
        chat.selectModel("b"); XCTAssertEqual(chat.effort, ""); XCTAssertTrue(chat.supportedEfforts.isEmpty)
    }
    @MainActor func testSelectingAnotherModelKeepsCompatibleStrength() {
        let chat = ChatSession()
        chat.models = ["a", "b"].map { name in
            .object(["model": .string(name), "defaultReasoningEffort": .string("medium"),
                     "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("medium")]), .object(["reasoningEffort": .string("high")])])])
        }
        chat.selectModel("a"); chat.effort = "high"
        chat.selectModel("b")
        XCTAssertEqual(chat.effort, "high")
    }
    @MainActor func testDefaultModelOffersOnlyItsOwnSupportedStrengths() {
        let chat = ChatSession()
        chat.models = [.object(["model": .string("default-model"), "isDefault": .bool(true),
                               "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("low")]), .object(["reasoningEffort": .string("high")])])]),
                       .object(["model": .string("other"), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("medium")])])])]
        chat.selectModel("")
        XCTAssertEqual(chat.supportedEfforts, ["low", "high"])
        chat.effort = "high"
        chat.selectModel("other")
        XCTAssertEqual(chat.effort, "")
        XCTAssertEqual(chat.supportedEfforts, ["medium"])
    }
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
    func testUserInputBlocksStayVisibleOutsideTools() throws {
        let data = Data(#"[{"id":"u1","role":"system","content":"Hello","metadata":{"blockType":"userMessage"}},{"id":"u2","type":"userInput","content":"Still here"},{"id":"a1","role":"agent","content":"Yes"}]"#.utf8)
        let messages = try JSONDecoder().decode([JSONValue].self, from: data)
        XCTAssertTrue(ChatPresentation.isUser(messages[0]))
        XCTAssertTrue(ChatPresentation.isUser(messages[1]))
        XCTAssertEqual(ChatPresentation.rows(messages).map(\.activity), [false, false, false])
    }
    func testUserHistoryRecoveryPreservesRepliesAndHonorsDeletions() throws {
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"t","turns":[{"id":"turn1","items":[{"id":"u1","type":"userMessage","content":[{"type":"inputText","text":"hello"}]}]}]}}"#.utf8))
        let reply: JSONValue = .object(["id": .string("a1"), "role": .string("agent"), "content": .string("hi"), "metadata": .object(["turnId": .string("turn1")])])
        let restored = UserHistoryRecovery.merge([reply], snapshot: snapshot, conversationID: "c", tombstones: [])
        XCTAssertEqual(restored.map(\.id), ["u1", "a1"])
        XCTAssertEqual(restored[0]["content"].string, "hello")
        XCTAssertEqual(restored[0]["createdAt"].string, "")
        XCTAssertEqual(UserHistoryRecovery.merge(restored, snapshot: snapshot, conversationID: "c", tombstones: []), restored)
        XCTAssertEqual(UserHistoryRecovery.merge([reply], snapshot: snapshot, conversationID: "c", tombstones: [.object(["itemId": .string("u1")])]), [reply])
    }
    func testMorningDreamInternalPromptStaysOutOfChatWhileTraceRemains() throws {
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"ash-thread","turns":[{"id":"dream-turn","items":[{"id":"internal","type":"userMessage","content":[{"type":"inputText","text":"[Vesper morning dream — not user content: sleep cycle 1] dream prompt"}]},{"type":"reasoning","summary":["A public summary"]},{"type":"dynamicToolCall","tool":"remember_vesper_memory","status":"completed"},{"id":"greeting","type":"agentMessage","text":"早上好，Vera。"}]}]}}"#.utf8))
        let greeting: JSONValue = .object(["id": .string("greeting"), "role": .string("agent"), "content": .string("早上好，Vera。"), "metadata": .object(["wakeRunId": .string("dream:1")])])
        let restored = UserHistoryRecovery.merge([greeting], snapshot: snapshot, conversationID: "ash", tombstones: [])
        XCTAssertEqual(restored.map(\.id), ["greeting"])
        XCTAssertEqual(restored[0]["metadata"]["thoughtSummary"].string, "A public summary")
        XCTAssertEqual(restored[0]["metadata"]["toolEvents"].array.map { $0.string }, ["remember_vesper_memory · completed"])
    }
    func testToolDetailsAttachToReplyWithoutHidingUserMessages() throws {
        let data = Data(#"[{"id":"u","role":"user","content":"Hi"},{"id":"tool","role":"system","metadata":{"turnId":"t","execution":{"title":"Read"}}},{"id":"a","role":"agent","content":"Hello","metadata":{"turnId":"t"}}]"#.utf8)
        let messages = try JSONDecoder().decode([JSONValue].self, from: data)
        let rows = ChatPresentation.displayRows(messages)
        XCTAssertEqual(rows.map(\.id), ["u", "a"])
        XCTAssertTrue(rows[0].activities.isEmpty)
        XCTAssertEqual(rows[1].activities.map(\.id), ["tool"])
    }
    func testHistoryDatesHandleBothTimestampFormats() {
        XCTAssertFalse(ChatPresentation.time("2026-09-12T23:49:25.235339Z").isEmpty)
        XCTAssertFalse(ChatPresentation.time("2026-09-12T23:49:25Z").isEmpty)
        XCTAssertEqual(ChatPresentation.time("invalid"), "")
        XCTAssertFalse(ChatPresentation.time("2026-09-12T23:49:25.235339Z").contains("2026-09-12T"))
    }

    @MainActor func testJSONRPCUsesTextFrames() throws {
        let packet: JSONValue = .object(["id": .string("usage-read"), "method": .string("account/rateLimits/read")])
        let message = try ChatSession.wireMessage(packet)
        guard case .string(let text) = message else { return XCTFail("JSON-RPC must use WebSocket text frames") }
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), packet)
    }
    @MainActor func testMusicQueueRemainsSeparateFromLibraryRefresh() {
        let a: JSONValue = .object(["id": .string("a"), "title": .string("A")])
        let b: JSONValue = .object(["id": .string("b"), "title": .string("B")])
        let player = MusicPlayer()
        player.updateLibrary([a])
        player.setQueue([b, b])
        player.updateLibrary([a, b])
        XCTAssertEqual(player.tracks.map(\.id), ["b"])
        XCTAssertEqual(player.track.id, "b")
        player.setQueue([a, b], append: true)
        XCTAssertEqual(player.tracks.map(\.id), ["b", "a"])
        player.remove("b")
        XCTAssertEqual(player.track.id, "a")
        player.remove("a")
        XCTAssertEqual(player.track, .null)
    }

    func testTimedLRCParsesRepeatedTimestampsAndSkipsMetadata() {
        let lines = NetEaseTimedLyrics.parse("[ar:Artist]\n[00:03.50][00:05.125]First line\n[00:08.00]Second line")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map { $0["time"].number }, [3.5, 5.125, 8])
        XCTAssertEqual(lines.map { $0["text"].string }, ["First line", "First line", "Second line"])
    }

    func testLegacyTextRecoveryMatchesOnceAndPreservesRepeatedSends() throws {
        let saved = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"id":"local1","role":"user","content":"再试一次","createdAt":"2026-09-14T02:43:36.000Z"},{"id":"local2","role":"user","content":"再试一次","createdAt":"2026-09-14T02:50:30Z"}]"#.utf8))
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"turns":[{"id":"t1","startedAt":"2026-09-14T02:43:37Z","items":[{"id":"remote1","type":"userMessage","text":"再试一次"}]},{"id":"t2","startedAt":"2026-09-14T02:50:32Z","items":[{"id":"remote2","type":"userMessage","text":"再试一次"}]}]}"#.utf8))
        let merged = UserHistoryRecovery.merge(saved, snapshot: snapshot, conversationID: "c", tombstones: [])
        XCTAssertEqual(merged.map(\.id), ["local1", "local2"])
        XCTAssertEqual(merged[0]["metadata"]["itemId"].string, "remote1")
        XCTAssertEqual(merged[1]["metadata"]["itemId"].string, "remote2")
        XCTAssertEqual(UserHistoryRecovery.merge(merged, snapshot: snapshot, conversationID: "c", tombstones: []), merged)
        var unknown = saved
        unknown[0]["createdAt"] = .string("")
        XCTAssertEqual(UserHistoryRecovery.merge(unknown, snapshot: snapshot, conversationID: "c", tombstones: []).count, 3)
        var ambiguous = saved
        var duplicate = saved[0]; duplicate["id"] = .string("second-real-send")
        ambiguous.append(duplicate)
        XCTAssertEqual(UserHistoryRecovery.merge(ambiguous, snapshot: snapshot, conversationID: "c", tombstones: []).count, 4)
    }

    func testAttachmentContextDoesNotBecomeASecondUserMessage() throws {
        let saved = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"id":"local","role":"user","content":"看看附件","metadata":{"attachments":[{"name":"note.md","url":"https://example.test/note.md"}]}}]"#.utf8))
        let expanded = "看看附件\nAttachment: note.md (text/markdown)\nDownload: https://example.test/note.md\nFile preview:\nprivate file body"
        let snapshot: JSONValue = .object(["turns": .array([.object(["id": .string("turn"), "items": .array([.object(["id": .string("remote"), "type": .string("userMessage"), "text": .string(expanded)])])])])])
        let merged = UserHistoryRecovery.merge(saved, snapshot: snapshot, conversationID: "c", tombstones: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0]["content"].string, "看看附件")
        XCTAssertEqual(merged[0]["metadata"]["attachments"], saved[0]["metadata"]["attachments"])
        XCTAssertEqual(UserHistoryRecovery.merge(merged, snapshot: snapshot, conversationID: "c", tombstones: []), merged)
        var different = saved
        different[0]["metadata"]["attachments"] = .array([.object(["name": .string("other.md"), "url": .string("https://example.test/other.md")])])
        XCTAssertEqual(UserHistoryRecovery.merge(different, snapshot: snapshot, conversationID: "c", tombstones: []).count, 2)
    }

    func testToolFileDeliveryProducesPersistentVisibleAttachmentMessage() {
        let file: JSONValue = .object(["key": .string("file.md"), "url": .string("https://example.com/api/media/file.md"), "name": .string("note.md"), "type": .string("application/octet-stream"), "size": .number(12)])
        let result: JSONValue = .object(["attachments": .array([file]), "message": .string("A note")])
        let message = ChatFileDelivery.message(result, conversationID: "c", threadID: "t", turnID: "turn", callID: "call", createdAt: "2026-09-14T02:43:00Z")
        XCTAssertEqual(message.id, "files:t:call")
        XCTAssertEqual(message["metadata"]["attachments"], .array([file]))
        XCTAssertEqual(message["conversationId"].string, "c")
        XCTAssertFalse(ChatPresentation.isActivity(message))
        XCTAssertEqual(ChatPresentation.displayRows([message]).map(\.id), [message.id])
        XCTAssertEqual(ChatFileDelivery.message(result, conversationID: "c", threadID: "t", turnID: "turn", callID: "call", createdAt: "later").id, message.id)
    }

    func testAttachmentOnlyDeliveryHasNonemptyHistoryContent() {
        for caption in [JSONValue.null, .string(""), .string(" \n\t")] {
            let result: JSONValue = .object(["message": caption, "attachments": .array([.object(["name": .string("note.md")])])])
            let message = ChatFileDelivery.message(result, conversationID: "c", threadID: "t", turnID: "turn", callID: "call", createdAt: "now")
            XCTAssertEqual(message["content"].string, "文件")
            XCTAssertEqual(message["metadata"]["attachmentOnly"], .bool(true))
            XCTAssertEqual(message["metadata"]["attachments"], result["attachments"])
        }
    }

}

@MainActor private final class RecoverySocket: ChatSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var closeReason: Data?
    var packets: [JSONValue] = []
    var snapshot: JSONValue = .object(["thread": .object(["id": .string("thread"), "turns": .array([])])])
    var loseReceipt = false
    var failInitialize = false
    var ignoreCancel = false
    var rejectTurn = false
    var pingCount = 0
    private var connectionPings = 0
    var pingFailure = false
    var handshakeStatus: Int?
    var handshakeFailure = false
    var hangHandshake = false
    var hangAfterFirstPing = false
    var hangMethod: String?
    var itemPage: JSONValue?
    var modelPage: JSONValue?
    var endlessPages = false
    var rejectMethod: String?
    var hangInitialized = false
    private var suspended: [CheckedContinuation<Void, Error>] = []
    func releaseSuspended() { let waits = suspended; suspended = []; for wait in waits { wait.resume() } }
    private var queue: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func resume() { connectionPings = 0 }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode; closeReason = reason
        if !ignoreCancel { fail() }
    }
    func fail() {
        let continuation = waiter; waiter = nil
        continuation?.resume(throwing: URLError(.networkConnectionLost))
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func emit(_ packet: JSONValue) throws {
        let message = try ChatSession.wireMessage(packet)
        if let continuation = waiter { waiter = nil; continuation.resume(returning: message) }
        else { queue.append(message) }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        let packet = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)); packets.append(packet)
        let method = packet["method"].string
        if method == hangMethod { return }
        if method == rejectMethod {
            try emit(.object(["id": packet["id"], "error": .object(["code": .number(-32602), "message": .string("never-log-this-token")])]))
            return
        }
        if method == "initialized", hangInitialized {
            try await withCheckedThrowingContinuation { suspended.append($0) }
            return
        }
        if method == "initialize", failInitialize { throw URLError(.networkConnectionLost) }
        if method == "turn/start", loseReceipt { throw URLError(.networkConnectionLost) }
        if method == "turn/start", rejectTurn {
            try emit(.object(["id": packet["id"], "error": .object(["message": .string("Request rejected")])]))
            return
        }
        if packet["id"] != .null && !method.isEmpty {
            var response = method == "thread/resume" ? snapshot : (method == "thread/items/list" ? itemPage ?? .object([:]) : (method == "model/list" ? modelPage ?? .object([:]) : .object([:])))
            if method == "thread/items/list", endlessPages { response["nextCursor"] = .string("page-" + String(packets.count)) }
            try emit(.object(["id": packet["id"], "result": response]))
        }
    }
    func ping() async throws {
        pingCount += 1; connectionPings += 1
        if connectionPings == 1 {
            if hangHandshake { try await withCheckedThrowingContinuation { suspended.append($0) } }
            if handshakeFailure { throw URLError(.badServerResponse) }
        } else if hangAfterFirstPing { try await withCheckedThrowingContinuation { suspended.append($0) } }
        else if pingFailure { throw URLError(.networkConnectionLost) }
    }
}

@MainActor private final class SuspendedHistory {
    var waits: [CheckedContinuation<JSONValue, Error>] = []
    func read() async throws -> JSONValue { try await withCheckedThrowingContinuation { waits.append($0) } }
    func release(_ value: JSONValue) {
        let pending = waits; waits = []
        for wait in pending { wait.resume(returning: value) }
    }
}

private final class SendPreparationProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var held: [SendPreparationProtocol] = []
    private static var holdHistory = false
    private static var failHistory = false
    private static var timeoutHistory = false
    private static var holdHistoryPath: String?
    static var failMemory = false
    static var deletedRoom = false
    static var agentDocument: JSONValue = .null
    static func history(hold: Bool = false, fail: Bool = false, timeout: Bool = false, holdPath: String? = nil) {
        lock.lock(); holdHistory = hold; failHistory = fail; timeoutHistory = timeout; holdHistoryPath = holdPath; lock.unlock()
    }
    static func releaseHistory() {
        lock.lock(); let pending = held; held = []; holdHistory = false; holdHistoryPath = nil; lock.unlock()
        for request in pending { request.finish(status: 200) }
    }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = []; holdHistory = false; failHistory = false; timeoutHistory = false; holdHistoryPath = nil; failMemory = false; deletedRoom = false; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "send-preparation.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request)
        let history = request.url!.path.hasPrefix("/conversations/")
        let held = history && (Self.holdHistory || request.url?.path == Self.holdHistoryPath), failed = history && Self.failHistory
        let timedOut = history && Self.timeoutHistory
        if held { Self.held.append(self) }
        Self.lock.unlock()
        if held { return }
        if timedOut { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        finish(status: Self.deletedRoom && request.url!.path.hasPrefix("/conversations/deleted") ? 410 : failed || (Self.failMemory && request.url?.path == "/api/memory/messages") ? 503 : 200)
    }
    private func finish(status: Int) {
        if request.url?.path == "/agent-instructions" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(Self.agentDocument))
            client?.urlProtocolDidFinishLoading(self); return
        }
        if request.url?.path == "/api/media" {
            let value: JSONValue = .object(["key": .string(UUID().uuidString), "url": .string("https://send-preparation.example/media/" + UUID().uuidString), "name": .string("fixture"), "type": .string("image/jpeg")])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value))
            client?.urlProtocolDidFinishLoading(self); return
        }
        let body = status == 410 ? #"{"error":"Conversation was deleted","code":"conversation_deleted"}"# : request.url!.path == "/api/codex/tools" ? #"{"tools":[]}"# : #"{"status":"prepared","deliveryId":"fixture","additionalContext":{}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.held.removeAll { $0 === self }; Self.lock.unlock() }
}

@MainActor final class ChatConnectionRecoveryTests: XCTestCase {
    func testSharedInstructionsRefreshExistingChatAndKeepProjectAndCallContext() async throws {
        let savedReplyMode = UserDefaults.standard.object(forKey: "chatReplyMode")
        defer {
            if let savedReplyMode { UserDefaults.standard.set(savedReplyMode, forKey: "chatReplyMode") }
            else { UserDefaults.standard.removeObject(forKey: "chatReplyMode") }
        }
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config), socket = RecoverySocket()
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        defer {
            chat.disconnect(); outbox.stop(); http.invalidateAndCancel(); SendPreparationProtocol.agentDocument = .null
            if let key = ChatOrganization.key(api) { UserDefaults.standard.removeObject(forKey: key) }
        }
        func document(_ content: String) -> JSONValue {
            .object(["version": .number(1), "source": .string("AGENTS.md"), "content": .string(content),
                     "revision": .string(SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())])
        }
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread", loadSharedInstructions: true)
        chat.model = ""; chat.effort = ""; chat.replyMode = .immediate
        chat.voiceCallContext = "Call scene fixture"
        var organization = ChatOrganization()
        organization.contactInstructions = "Contact fixture"
        let project = ChatProject(name: "Study", instructions: "Project fixture")
        organization.projects = [project]; organization.move(chat.conversationID, to: project.id); try organization.save(api)
        for content in ["Shared identity first", "Shared identity updated"] {
            SendPreparationProtocol.agentDocument = document(content)
            chat.busy = false
            let sent = await chat.send("fixture")
            XCTAssertTrue(sent)
            let instruction = try XCTUnwrap(socket.packets.last { $0["method"].string == "thread/resume" })["params"]["developerInstructions"].string
            XCTAssertTrue(instruction.contains(content)); XCTAssertTrue(instruction.contains("Call scene fixture"))
            XCTAssertTrue(instruction.contains("Contact fixture")); XCTAssertTrue(instruction.contains("Project fixture"))
            if content.hasSuffix("updated") { XCTAssertFalse(instruction.contains("Shared identity first")) }
        }
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "thread/start" })
        let count = socket.packets.filter { $0["method"].string == "turn/start" }.count
        SendPreparationProtocol.agentDocument = .null; chat.busy = false
        let sent = await chat.send("Must not submit with missing shared rules")
        XCTAssertFalse(sent)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, count)
        var invalid = document("Fixture"); invalid["revision"] = .string("wrong")
        XCTAssertThrowsError(try SharedAgentInstructions(invalid))
    }
    func testCollectedVideosDoNotCreateAnUnsendableMultiVideoQueue() async throws {
        let api = APIClient(baseURL: "https://video-queue.fixture", historyURL: "https://video-queue.fixture", token: UUID().uuidString)
        let chat = ChatSession(); chat.configureConnection(api: api, endpoint: "wss://video-queue.fixture")
        chat.replyMode = .collected
        defer { chat.disconnect(); if let file = try? ChatQueuedStore.url(api: api, conversationID: chat.conversationID) { try? FileManager.default.removeItem(at: file) } }
        let clip = ChatFile(name: "clip.mp4", mime: "video/mp4", data: Data([1]), duration: 1, videoFrames: [ChatVideoFrame(seconds: 0, jpeg: Data([1]))])
        let first = await chat.send("first", files: [clip]); XCTAssertTrue(first)
        let second = await chat.send("second", files: [clip]); XCTAssertFalse(second)
        XCTAssertEqual(chat.queuedMessages.count, 1)
        XCTAssertTrue(chat.error?.contains("已有一个视频") == true)
    }
    func testVideoSendUploadsOneClipAndSuppliesTimedFramesInSameTurn() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config), socket = RecoverySocket()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: directory)
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""; chat.replyMode = .immediate
        let file = ChatFile(name: "clip.mp4", mime: "video/mp4", data: Data("synthetic-movie".utf8), transcript: "Fixture dialogue", duration: 2, videoFrames: [ChatVideoFrame(seconds: 0, jpeg: Data([1])), ChatVideoFrame(seconds: 1, jpeg: Data([2]))], videoAudioNote: "Recognized speech only.")
        let sent = await chat.send("看看这个", files: [file]); XCTAssertTrue(sent)
        let turns = socket.packets.filter { $0["method"].string == "turn/start" }
        XCTAssertEqual(turns.count, 1)
        let input = try XCTUnwrap(turns.first)["params"]["input"].array
        XCTAssertEqual(input.filter { $0["type"].string == "image" }.count, 2)
        let text = input.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("0.00 seconds")); XCTAssertTrue(text.contains("1.00 seconds")); XCTAssertTrue(text.contains("Fixture dialogue"))
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/api/media" }.count, 1)
        let attachment = try XCTUnwrap(chat.messages.first { $0["role"].string == "user" })["metadata"]["attachments"].array.first ?? .null
        XCTAssertEqual(attachment["type"].string, "video/mp4")
        XCTAssertEqual(attachment["duration"].number, 2)
        XCTAssertTrue(attachment["thumbnail"].string.hasPrefix("data:image/jpeg;base64,"))
    }
    func testMovingExistingChatAppliesAndRemovesProjectInstructionWithoutNewThread() async throws {
        let savedReplyMode = UserDefaults.standard.object(forKey: "chatReplyMode")
        defer {
            if let savedReplyMode { UserDefaults.standard.set(savedReplyMode, forKey: "chatReplyMode") }
            else { UserDefaults.standard.removeObject(forKey: "chatReplyMode") }
        }
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config), socket = RecoverySocket()
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        defer {
            chat.disconnect(); outbox.stop(); http.invalidateAndCancel()
            if let key = ChatOrganization.key(api) { UserDefaults.standard.removeObject(forKey: key) }
        }
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""; chat.replyMode = .immediate
        var organization = ChatOrganization()
        let project = ChatProject(name: "Study", instructions: "Project-only fixture")
        organization.projects = [project]; organization.contactInstructions = "Contact-only fixture"
        organization.move(chat.conversationID, to: project.id)
        try organization.save(api)
        let first = await chat.send("first")
        XCTAssertTrue(first)
        let firstConfig = try XCTUnwrap(socket.packets.last { $0["method"].string == "thread/resume" })
        XCTAssertTrue(firstConfig["params"]["developerInstructions"].string.contains("Project-only fixture"))
        XCTAssertTrue(firstConfig["params"]["developerInstructions"].string.contains("Contact-only fixture"))
        organization.move(chat.conversationID, to: nil); try organization.save(api)
        chat.busy = false
        let second = await chat.send("second")
        XCTAssertTrue(second)
        let secondConfig = try XCTUnwrap(socket.packets.last { $0["method"].string == "thread/resume" })
        XCTAssertEqual(secondConfig["params"]["threadId"].string, "thread")
        XCTAssertFalse(secondConfig["params"]["developerInstructions"].string.contains("Project-only fixture"))
        XCTAssertTrue(secondConfig["params"]["developerInstructions"].string.contains("Contact-only fixture"))
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "thread/start" })
        try await outbox.flush(api)
    }
    func testEditedChatPromptAppliesToExistingThreadOnceAndCanBeCleared() async throws {
        let savedReplyMode = UserDefaults.standard.object(forKey: "chatReplyMode")
        defer {
            if let savedReplyMode { UserDefaults.standard.set(savedReplyMode, forKey: "chatReplyMode") }
            else { UserDefaults.standard.removeObject(forKey: "chatReplyMode") }
        }
        let previous = UserDefaults.standard.object(forKey: ChatPromptPreferences.key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: ChatPromptPreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: ChatPromptPreferences.key) }
        }
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        let socket = RecoverySocket()
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""; chat.replyMode = .immediate
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel() }
        ChatPromptPreferences.save("Initial preference fixture")
        let first = await chat.send("first")
        XCTAssertTrue(first)
        let firstResume = try XCTUnwrap(socket.packets.last { $0["method"].string == "thread/resume" })
        XCTAssertTrue(firstResume["params"]["developerInstructions"].string.contains("Initial preference fixture"))
        let resumes = socket.packets.filter { $0["method"].string == "thread/resume" }.count
        ChatPromptPreferences.save("Updated preference fixture")
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, resumes, "Saving must not interrupt a running reply")
        chat.busy = false
        let second = await chat.send("second")
        XCTAssertTrue(second)
        let updated = try XCTUnwrap(socket.packets.last { $0["method"].string == "thread/resume" })
        XCTAssertEqual(updated["params"]["threadId"].string, "thread")
        XCTAssertTrue(updated["params"]["developerInstructions"].string.contains("Updated preference fixture"))
        XCTAssertFalse(updated["params"]["developerInstructions"].string.contains("Initial preference fixture"))
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, resumes + 1)
        chat.busy = false
        let third = await chat.send("third")
        XCTAssertTrue(third)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, resumes + 1, "Unchanged prompts must not add preparation on each send")
        ChatPromptPreferences.save("")
        XCTAssertEqual(ChatPromptPreferences.load(), "")
        chat.busy = false
        let fourth = await chat.send("fourth")
        XCTAssertTrue(fourth)
        let cleared = try XCTUnwrap(socket.packets.last { $0["method"].string == "thread/resume" })
        XCTAssertFalse(cleared["params"]["developerInstructions"].string.contains("Vera's chat preferences:"))
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "thread/start" }, "Editing must preserve the existing thread")
        try await outbox.flush(api)
    }

    private func session(_ sockets: [RecoverySocket], heartbeat: Double = 1000, stableInterval: Double = 60, timeout: Double = 5, attemptTimeout: Double? = nil, historyReader: ((String) async throws -> JSONValue)? = nil) -> ChatSession {
        var index = 0
        let chat = ChatSession(socketFactory: { _ in
            let socket = sockets[min(index, sockets.count - 1)]; index += 1; return socket
        }, delay: { seconds in
            try await Task.sleep(for: .milliseconds(seconds >= 100 ? 100_000 : 5))
        }, heartbeatInterval: heartbeat, requestTimeout: timeout, stableConnectionInterval: stableInterval, attemptTimeout: attemptTimeout)
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"), endpoint: "wss://invalid.example", threadID: "thread", historyReader: historyReader)
        return chat
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testBackendChangeDiscardsOldModelCatalogAndLateLoadFailure() async throws {
        let oldSocket = RecoverySocket(); oldSocket.hangMethod = "model/list"
        let newSocket = RecoverySocket()
        newSocket.modelPage = .object(["data": .array([.object(["model": .string("mac-only"), "isDefault": .bool(true)])])])
        let chat = session([oldSocket, newSocket])
        defer { chat.disconnect() }
        chat.models = [.object(["model": .string("vps-only"), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("high")])])])]
        chat.model = "vps-only"; chat.effort = "high"
        let pending = Task { await chat.loadModels() }
        await eventually { oldSocket.packets.contains { $0["method"].string == "model/list" } }
        let store = AppStore()
        store.baseURL = "https://mac-fixture.invalid"; store.historyURL = "https://mac-fixture.invalid/history"
        store.socketURL = "wss://mac-fixture.invalid/chat"; store.token = "synthetic-backend-token"
        chat.configure(store)
        XCTAssertTrue(chat.models.isEmpty)
        XCTAssertEqual(chat.model, ""); XCTAssertEqual(chat.effort, "")
        XCTAssertFalse(chat.loadingModels)
        await chat.loadModels()
        await pending.value
        XCTAssertEqual(chat.models.map { $0["model"].string }, ["mac-only"])
        XCTAssertNil(chat.modelError)
        XCTAssertFalse(chat.loadingModels)
        XCTAssertFalse(newSocket.packets.contains { $0["method"].string == "thread/resume" })
        chat.selectModel("mac-only")
        chat.configure(store)
        XCTAssertEqual(chat.model, "mac-only", "Opening the picker again must keep the same backend's selection.")
    }
    func testRepeatedSendsReuseToolsAndSessionWithoutReadingHistory() async throws {
        SendPreparationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let socket = RecoverySocket()
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { outbox.stop() }
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "fixture", requestSession: http)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""
        defer { chat.disconnect() }
        let first = await chat.send("first message")
        XCTAssertTrue(first)
        let resumed = socket.packets.filter { $0["method"].string == "thread/resume" }.count
        chat.busy = false
        let second = await chat.send("second message with different references")
        XCTAssertTrue(second)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, resumed)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 2)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/api/codex/tools" }.count, 1)
        XCTAssertFalse(SendPreparationProtocol.captured.contains { $0.httpMethod == "GET" && $0.url!.path.hasPrefix("/conversations/") })
        let inputs = socket.packets.filter { $0["method"].string == "turn/start" }.last!["params"]["input"].array
        XCTAssertTrue(inputs.contains { $0["text"].string.contains("first message") })
        XCTAssertFalse(SendPreparationProtocol.captured.contains { $0.url?.path == "/api/memory/context" })
        chat.busy = false
        chat.disconnect()
        let third = await chat.send("after reconnect")
        XCTAssertTrue(third)
        XCTAssertGreaterThan(socket.packets.filter { $0["method"].string == "thread/resume" }.count, resumed)
        try await outbox.flush(api)
    }
    func testChangedThreadPolicyResumesOnceBeforeNextSend() async throws {
        SendPreparationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: configuration)
        let socket = RecoverySocket()
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "fixture", requestSession: http)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel() }
        let first = await chat.send("first")
        XCTAssertTrue(first)
        let before = socket.packets.filter { $0["method"].string == "thread/resume" }.count
        chat.busy = false
        chat.refreshThreadPolicyOnNextSend()
        let sent = await chat.send("after change")
        XCTAssertTrue(sent)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, before + 1)
        chat.busy = false
        let again = await chat.send("next")
        XCTAssertTrue(again)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, before + 1)
    }
    func testSendDoesNotWaitForCloudAndRecallRunsOnlyAsATool() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.history(hold: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""
        defer { chat.disconnect(); outbox.stop(); SendPreparationProtocol.releaseHistory(); http.invalidateAndCancel() }
        let task = Task { await chat.send("A new message without waiting for history storage") }
        await eventually { socket.packets.contains { $0["method"].string == "turn/start" } }
        let accepted = await task.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(SendPreparationProtocol.captured.contains { $0.url?.path == "/api/memory/context" })
        XCTAssertEqual(try outbox.pending(api, conversationID: chat.conversationID).count, 1)
        XCTAssertEqual(chat.messages.last?["status"].string, "delivered")
        let tools = socket.packets.last { $0["method"].string == "thread/resume" }!["params"]["dynamicTools"].array
        XCTAssertTrue(tools.contains { $0["name"].string == "recall_native_memory" })
        try socket.emit(.object(["id": .string("recall"), "method": .string("item/tool/call"), "params": .object([
            "name": .string("recall_native_memory"), "callId": .string("recall"), "threadId": .string("thread"),
            "turnId": .string("turn"), "arguments": .object(["query": .string("An earlier agreement")])])]))
        await eventually { socket.packets.contains { $0["id"].string == "recall" && $0["result"] != .null } }
        XCTAssertTrue(SendPreparationProtocol.captured.contains { $0.url?.path == "/api/memory/context" })
        XCTAssertEqual(socket.packets.last { $0["id"].string == "recall" }?["result"]["success"], .bool(true))
        SendPreparationProtocol.releaseHistory()
        try await outbox.flush(api)
        XCTAssertTrue(try outbox.pending(api, conversationID: chat.conversationID).isEmpty)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 1)
    }
    func testDiscardingLastFailedUploadClearsStaleSyncWarning() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.history(fail: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel(); SendPreparationProtocol.reset() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "discard-warning", requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { outbox.stop() }
        var notice = ""
        outbox.activate(api) { notice = $0 }
        try outbox.enqueue(.object(["id": .string("m"), "conversationId": .string("deleted"), "role": .string("user"), "content": .string("saved"), "status": .string("delivered")]), conversation: .object([:]), api: api)
        do { try await outbox.flush(api); XCTFail("Expected upload failure") } catch {}
        XCTAssertFalse(notice.isEmpty)
        try outbox.discard(api, conversationID: "deleted")
        XCTAssertEqual(notice, "")
        try await outbox.flush(api)
    }
    func testHistoryRetryClearsTimeoutBeforeBacklogFinishes() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.history(timeout: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel(); SendPreparationProtocol.reset() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "retry-timeout", requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { outbox.stop(); SendPreparationProtocol.releaseHistory() }
        var notice = ""
        outbox.activate(api) { notice = $0 }
        for room in ["first", "later"] {
            try outbox.enqueue(.object(["id": .string(room), "conversationId": .string(room), "role": .string("user"), "content": .string("saved"), "status": .string("delivered")]), conversation: .object([:]), api: api)
        }
        do { try await outbox.flush(api); XCTFail("Expected timeout") } catch {}
        XCTAssertTrue(notice.contains("同步请求超时"))
        SendPreparationProtocol.history(holdPath: "/conversations/later")
        outbox.activate(api)
        await eventually { SendPreparationProtocol.captured.contains { $0.url?.path == "/conversations/later" } }
        XCTAssertEqual(notice, "", "The old timeout must clear on a saved retry, before the remaining upload finishes")
        XCTAssertEqual(try outbox.pending(api, conversationID: "later").count, 1)
        SendPreparationProtocol.releaseHistory()
        try await outbox.flush(api)
        XCTAssertTrue(try outbox.pending(api, conversationID: "first").isEmpty)
        XCTAssertTrue(try outbox.pending(api, conversationID: "later").isEmpty)
    }
    func testBacklogWritesConversationOnceUntilThreadMappingChanges() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel(); SendPreparationProtocol.reset() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "backlog-headers", requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { outbox.stop() }
        for (index, thread) in ["thread-a", "thread-a", "thread-b"].enumerated() {
            try outbox.enqueue(.object(["id": .string("m\(index)"), "conversationId": .string("room"), "role": .string("user"), "content": .string("saved"), "status": .string("delivered")]), conversation: .object(["codexThreadId": .string(thread)]), api: api)
        }
        try await outbox.flush(api)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/conversations/room" }.count, 2)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/conversations/room/messages" }.count, 3)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/api/memory/messages" }.count, 3)
        XCTAssertTrue(try outbox.pending(api, conversationID: "room").isEmpty)
    }
    func testDeletedRoomDoesNotBlockOtherHistoryUploads() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.deletedRoom = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel(); SendPreparationProtocol.reset() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "deleted-room-test", requestSession: http)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: root); defer { outbox.stop() }
        for room in ["deleted", "live"] {
            try outbox.enqueue(.object(["id": .string(room), "conversationId": .string(room), "role": .string("user"), "content": .string("saved"), "status": .string("delivered")]), conversation: .object([:]), api: api)
        }
        try await outbox.flush(api)
        XCTAssertTrue(try outbox.pending(api, conversationID: "deleted").isEmpty)
        XCTAssertTrue(try outbox.pending(api, conversationID: "live").isEmpty)
        XCTAssertFalse(SendPreparationProtocol.captured.contains { $0.url?.path == "/conversations/deleted/messages" })
        XCTAssertTrue(SendPreparationProtocol.captured.contains { $0.url?.path == "/conversations/live/messages" })
        XCTAssertFalse(ServiceError(message: "missing", statusCode: 404).conversationDeleted)
        XCTAssertFalse(ServiceError(message: "gone", statusCode: 410).conversationDeleted)
    }
    func testMemoryFailureKeepsHistoryUploadedAndRetriesOnlyMemoryAfterRelaunch() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.failMemory = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel(); SendPreparationProtocol.reset() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "memory-checkpoint", requestSession: http)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ChatSendOutbox(directory: root); defer { first.stop() }
        var notice = ""
        first.activate(api) { notice = $0 }
        for id in ["first", "second"] {
            try first.enqueue(.object(["id": .string(id), "conversationId": .string("room"), "role": .string("user"), "content": .string("Saved history"), "status": .string("delivered")]), conversation: .object([:]), api: api)
        }
        do { try await first.flush(api); XCTFail("Memory failure remains queued") } catch {}
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/conversations/room/messages" }.count, 2)
        XCTAssertEqual(try first.pending(api, conversationID: "room").count, 2)
        XCTAssertTrue(notice.contains("聊天记录已上传"))
        XCTAssertTrue(notice.contains("记忆归档"))
        XCTAssertTrue(notice.contains("503"))
        XCTAssertFalse(notice.contains("联网后"))
        first.stop()
        SendPreparationProtocol.reset()
        let restored = ChatSendOutbox(directory: root); defer { restored.stop() }
        restored.activate(api) { notice = $0 }
        try await restored.flush(api)
        XCTAssertTrue(try restored.pending(api, conversationID: "room").isEmpty)
        XCTAssertEqual(notice, "")
        XCTAssertFalse(SendPreparationProtocol.captured.contains { $0.url?.path.hasPrefix("/conversations/") == true })
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/api/memory/messages" }.count, 2)
    }
    func testOutboxSurvivesRelaunchAndKeepsAccountsSeparate() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.history(fail: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "queue-account-a", requestSession: http)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = ChatSendOutbox(directory: root); defer { first.stop() }
        let message: JSONValue = .object(["id": .string("local-message"), "conversationId": .string("room"), "role": .string("user"), "content": .string("Saved locally"), "status": .string("delivered")])
        try first.enqueue(message, conversation: .object(["codexThreadId": .string("thread")]), api: api)
        do { try await first.flush(api); XCTFail("A failed upload must remain queued") } catch {}
        XCTAssertEqual(try first.pending(api, conversationID: "room"), [message])
        first.stop()
        let restored = ChatSendOutbox(directory: root); defer { restored.stop() }
        var other = api; other.token = "queue-account-b"
        XCTAssertTrue(try restored.pending(other, conversationID: "room").isEmpty)
        XCTAssertEqual(try restored.pending(api, conversationID: "room"), [message])
        SendPreparationProtocol.history()
        try await restored.flush(api)
        XCTAssertTrue(try restored.pending(api, conversationID: "room").isEmpty)
        let reloaded = ChatSendOutbox(directory: root)
        XCTAssertTrue(try reloaded.pending(api, conversationID: "room").isEmpty)
        XCTAssertTrue(SendPreparationProtocol.captured.contains { $0.url?.path == "/api/memory/messages" })
    }
    func testOutboxDoesNotUploadUnconfirmedSendsOrLoseNewerReceipts() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.history(hold: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "revisions", requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { outbox.stop(); SendPreparationProtocol.releaseHistory() }
        var message: JSONValue = .object(["id": .string("m"), "conversationId": .string("room"), "role": .string("user"), "content": .string("message"), "status": .string("pending")])
        try outbox.enqueue(message, conversation: .object([:]), api: api)
        XCTAssertTrue(SendPreparationProtocol.captured.isEmpty)
        message["status"] = .string("error")
        try outbox.enqueue(message, conversation: .object([:]), api: api)
        await eventually { !SendPreparationProtocol.captured.isEmpty }
        message["status"] = .string("delivered"); message["metadata"]["turnId"] = .string("confirmed-turn")
        try outbox.enqueue(message, conversation: .object([:]), api: api)
        SendPreparationProtocol.releaseHistory()
        try await outbox.flush(api)
        XCTAssertTrue(try outbox.pending(api, conversationID: "room").isEmpty)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/conversations/room/messages" }.count, 1)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/api/memory/messages" }.count, 1)
    }
    @MainActor func testStaleOutboxArchive() {
        do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: root); defer { outbox.stop() }
        let api = APIClient(baseURL: "https://stale-outbox.example", historyURL: "https://stale-outbox.example", token: "archive-test")
        let formatter = ISO8601DateFormatter()
        func message(_ id: String, age: TimeInterval, status: String = "pending") -> JSONValue {
            .object(["id": .string(id), "conversationId": .string("room"), "role": .string("user"),
                     "content": .string(id), "status": .string(status),
                     "createdAt": .string(formatter.string(from: Date().addingTimeInterval(-age)))])
        }
        let old = message("old-photo", age: 5 * 24 * 60 * 60)
        let recent = message("recent-pending", age: 10 * 60)
        let delivered = message("delivered", age: 5 * 24 * 60 * 60, status: "delivered")
        try outbox.enqueue(old, conversation: .object([:]), api: api)
        try outbox.enqueue(recent, conversation: .object([:]), api: api)
        // A confirmed record, even if old, must never be quarantined.
        let page = [message("page-start", age: 2 * 60 * 60, status: "delivered"),
                    message("page-end", age: 60, status: "delivered")]
        XCTAssertEqual(ChatSendOutbox.stalePendingIDs([old, recent, delivered], newerPage: page, hasOlder: true), ["old-photo"])
        XCTAssertTrue(ChatSendOutbox.stalePendingIDs([old], newerPage: page, hasOlder: false).isEmpty)
        XCTAssertEqual(try outbox.quarantineStalePending(api, conversationID: "room", newerPage: page, hasOlder: true), ["old-photo"])
        XCTAssertEqual(try outbox.pending(api, conversationID: "room").map(\.id), ["recent-pending"])
        let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".quarantined.json") })
        let archived = try JSONDecoder().decode([ChatSendOutbox.Entry].self, from: Data(contentsOf: archive))
        XCTAssertEqual(archived.map { $0.message.id }, ["old-photo"])
        let restored = ChatSendOutbox(directory: root)
        XCTAssertEqual(try restored.pending(api, conversationID: "room").map(\.id), ["recent-pending"])
        } catch { XCTFail(error.localizedDescription) }
    }
    func testRelaunchRecoversPendingReceiptWithoutResendingTheTurn() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "recover-receipt", requestSession: http)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = ChatSendOutbox(directory: directory)
        let message: JSONValue = .object(["id": .string("m"), "conversationId": .string("room"), "role": .string("user"), "content": .string("Previously submitted"), "status": .string("pending"), "metadata": .object(["threadId": .string("thread")])])
        try first.enqueue(message, conversation: .object(["codexThreadId": .string("thread")]), api: api)
        first.stop()
        let restored = ChatSendOutbox(directory: directory); defer { restored.stop() }
        let socket = RecoverySocket()
        socket.snapshot = .object(["thread": .object(["id": .string("thread"), "turns": .array([
            .object(["id": .string("accepted-turn"), "clientUserMessageId": .string("m"), "status": .string("completed"), "items": .array([])])])])])
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: restored)
        chat.newConversation(id: "room")
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.messages = try restored.pending(api, conversationID: "room")
        defer { chat.disconnect() }
        try await chat.connect()
        try await restored.flush(api)
        XCTAssertTrue(try restored.pending(api, conversationID: "room").isEmpty)
        XCTAssertEqual(chat.messages.first?["status"].string, "delivered")
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "turn/start" })
    }
    func testDeletingUnconfirmedLocalRecordDoesNotUploadOrReplayIt() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "pending-delete", requestSession: http)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: directory); defer { outbox.stop() }
        let message: JSONValue = .object(["id": .string("m"), "conversationId": .string("room"), "role": .string("user"), "content": .string("Unconfirmed"), "status": .string("pending")])
        try outbox.enqueue(message, conversation: .object([:]), api: api)
        try await outbox.flush(api)
        try outbox.discard(api, conversationID: "room", messageID: "m")
        let restored = ChatSendOutbox(directory: directory)
        XCTAssertTrue(try restored.pending(api, conversationID: "room").isEmpty)
        XCTAssertTrue(SendPreparationProtocol.captured.isEmpty)
    }
    func testFailedLocalSavePreventsModelSubmission() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file, not directory".utf8).write(to: root)
        let outbox = ChatSendOutbox(directory: root); defer { outbox.stop() }
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        chat.configureConnection(api: APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "fixture", requestSession: http), endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""; defer { chat.disconnect() }
        let sent = await chat.send("Must remain recoverable")
        XCTAssertFalse(sent)
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "turn/start" })
        XCTAssertEqual(chat.messages.last?["content"].string, "Must remain recoverable")
        XCTAssertEqual(chat.messages.last?["status"].string, "error")
    }
    func testPhaseRecoveryStopsAfterTwoPagesEvenWhenCursorNeverEnds() async throws {
        let socket = RecoverySocket()
        socket.itemPage = .object(["data": .array([]), "nextCursor": .string("next")]); socket.endlessPages = true
        let chat = session([socket]); defer { chat.disconnect() }
        chat.messages = [.object(["id": .string("old"), "role": .string("agent"), "content": .string("Old reply"), "metadata": .object(["threadId": .string("thread")])])]
        try await chat.connect()
        await eventually { socket.packets.filter { $0["method"].string == "thread/items/list" }.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/items/list" }.count, 2)
    }
    func testSendingCancelsHungPhaseRecoveryWithoutDisconnectingChat() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let socket = RecoverySocket(); socket.hangMethod = "thread/items/list"
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, requestTimeout: 0.1, sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread", prepareToolsOnConnect: true)
        chat.model = ""; chat.effort = ""
        chat.messages = [.object(["id": .string("old"), "role": .string("agent"), "content": .string("Old reply")])]
        defer { chat.disconnect(); outbox.stop() }
        try await chat.connect()
        await eventually { socket.packets.contains { $0["method"].string == "thread/items/list" } }
        let sent = await chat.send("Send takes priority")
        XCTAssertTrue(sent)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(chat.connectionStage, .ready)
        XCTAssertFalse(chat.connectionNeedsRetry)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, 1, "Opening must also install tools; sending must not resume again")
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/items/list" }.count, 1)
        try await outbox.flush(api)
    }
    func testSlowReplyStorageDoesNotBlockTurnCompletionOrLaterRPCs() async throws {
        SendPreparationProtocol.reset(); SendPreparationProtocol.history(hold: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        defer { chat.disconnect(); outbox.stop(); SendPreparationProtocol.releaseHistory(); http.invalidateAndCancel() }
        try await chat.connect()
        chat.busy = true
        try socket.emit(.object(["method": .string("turn/started"), "params": .object(["turn": .object(["id": .string("turn")])])]))
        try socket.emit(.object(["method": .string("item/completed"), "params": .object(["item": .object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string("Fresh reply"), "phase": .string("final_answer")])])]))
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object(["turn": .object(["id": .string("turn")])])]))
        await eventually { !chat.busy }
        XCTAssertEqual(chat.messages.last?["content"].string, "Fresh reply")
        let queued = try outbox.pending(api, conversationID: chat.conversationID)
        XCTAssertEqual(queued.first?["role"].string, "agent")
        await chat.loadModels()
        XCTAssertFalse(chat.loadingModels)
        XCTAssertTrue(socket.packets.contains { $0["method"].string == "model/list" })
        SendPreparationProtocol.releaseHistory()
        try await outbox.flush(api)
    }
    func testToolCatalogCacheCoalescesAndSeparatesAccounts() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        var api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: "account-a", requestSession: http)
        let cache = ChatToolCatalogCache()
        cache.prefetch(api)
        _ = try await cache.load(api)
        _ = try await cache.load(api)
        XCTAssertEqual(SendPreparationProtocol.captured.count, 1)
        api.token = "account-b"
        _ = try await cache.load(api)
        XCTAssertEqual(SendPreparationProtocol.captured.count, 2)
        XCTAssertEqual(SendPreparationProtocol.captured.last?.value(forHTTPHeaderField: "x-vesper-device-token"), "account-b")
        cache.refresh(api)
        _ = try await cache.load(api)
        await eventually { SendPreparationProtocol.captured.count == 3 }
    }
    func testSendPublishesLocalEchoBeforeConnectingAndConsumesComposerOnce() async throws {
        let socket = RecoverySocket(); socket.hangMethod = "initialize"
        let chat = session([socket], timeout: 0.05)
        defer { chat.disconnect() }
        chat.composer.draft = "A slow connection must not delay my message"
        var accepted = 0
        let draft = chat.composer.draft
        let task = Task {
            await chat.send(draft, onAccepted: {
                accepted += 1
                XCTAssertEqual(chat.messages.last?["content"].string, draft)
                XCTAssertEqual(chat.messages.last?["status"].string, "pending")
                XCTAssertEqual(chat.latestLocalMessageID, chat.messages.last?.id)
                XCTAssertTrue(chat.preparingSend)
                chat.composer.draft = ""
            })
        }
        await eventually { accepted == 1 }
        XCTAssertTrue(chat.composer.draft.isEmpty)
        let duplicate = await chat.send("duplicate", onAccepted: { accepted += 1 })
        XCTAssertFalse(duplicate)
        chat.composer.draft = "Next draft"
        _ = await task.value
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(chat.composer.draft, "Next draft")
        XCTAssertEqual(chat.messages.filter { $0["content"].string == draft }.count, 1)
    }

    func testLocationOnlySendImmediatelyPublishesShareCard() async throws {
        let socket = RecoverySocket(); socket.hangMethod = "initialize"
        let chat = session([socket], timeout: 0.05); defer { chat.disconnect() }
        let location: JSONValue = .object(["latitude": .number(31.27), "longitude": .number(120.74), "title": .string("Test location"), "horizontalAccuracyMeters": .number(10), "locatedAt": .string("2026-10-05T08:00:00Z")])
        var accepted = false
        _ = await chat.send("", location: location, onAccepted: {
            accepted = true
            XCTAssertEqual(chat.messages.last?["metadata"]["locationCard"], location)
            XCTAssertEqual(chat.messages.last?["metadata"]["locationOnly"], .bool(true))
        })
        XCTAssertTrue(accepted)
        XCTAssertTrue(ChatSharedLocation.context(location).contains("31.27"))
        let before = chat.messages.count
        let invalid = await chat.send("", location: .object(["latitude": .number(95), "longitude": .number(1)]))
        XCTAssertFalse(invalid)
        XCTAssertEqual(chat.messages.count, before)
    }

    func testAcceptedUserMessageKeepsItsTimestampWhileReplyRuns() async throws {
        let socket = RecoverySocket(); let chat = session([socket]); defer { chat.disconnect() }
        try await chat.connect()
        try socket.emit(.object(["method": .string("turn/started"), "params": .object(["turn": .object(["id": .string("active")])])]))
        await eventually { chat.busy }
        let user: JSONValue = .object(["role": .string("user"), "metadata": .object(["turnId": .string("active")])])
        var reply = user; reply["role"] = .string("agent")
        XCTAssertFalse(chat.replyIsStillRunning(user))
        XCTAssertTrue(chat.replyIsStillRunning(reply))
    }

    func testUnansweredTerminalTurnSharesOneHeadingWithoutCrossingTurnsOrQuestions() {
        func command(_ id: String, turn: String = "turn", thread: String = "thread", second: Int) -> JSONValue {
            .object(["id": .string(id), "conversationId": .string("chat"), "role": .string("system"),
                "createdAt": .string(String(format: "2026-10-07T01:00:%02dZ", second)),
                "metadata": .object(["turnId": .string(turn), "threadId": .string(thread),
                    "execution": .object(["type": .string("commandExecution"), "status": .string("failed"), "command": .string("echo fixture")])])])
        }
        let first = command("a", second: 1), second = command("b", second: 2), third = command("c", second: 3)
        let grouped = ChatPresentation.displayRows([first, second, third])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertTrue(grouped[0].activity)
        XCTAssertEqual(grouped[0].activities.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ChatTerminalRecords.entries(grouped[0].activities).count, 3)
        XCTAssertEqual(ChatPresentation.liveHeadingID(grouped, turnID: "turn"), "a")
        XCTAssertEqual(ChatPresentation.displayRows([first, command("other", turn: "other", second: 2)]).count, 2)
        XCTAssertEqual(ChatPresentation.displayRows([first, command("other", thread: "other", second: 2)]).count, 2)
        XCTAssertEqual(ChatPresentation.displayRows([command("legacy-a", turn: "", second: 1), command("legacy-b", turn: "", second: 2)]).count, 2)
        var question = second
        question["metadata"]["userInput"] = .object(["id": .string("question")])
        XCTAssertEqual(ChatPresentation.displayRows([first, question, third]).count, 3)
        var reply = third
        reply["id"] = .string("reply"); reply["role"] = .string("agent")
        reply["metadata"]["execution"] = .null
        let answered = ChatPresentation.displayRows([first, second, reply])
        XCTAssertEqual(answered.count, 1)
        XCTAssertEqual(answered[0].id, "reply")
        XCTAssertEqual(answered[0].activities.map(\.id), ["a", "b"])
        reply["metadata"]["threadId"] = .string("different-thread")
        XCTAssertEqual(ChatPresentation.displayRows([first, reply]).count, 2)
    }

    func testLiveHeadingUsesCurrentTurnAndMovesFromToolToReply() {
        func message(_ id: String, role: String = "agent", turn: String) -> JSONValue {
            .object(["id": .string(id), "role": .string(role), "createdAt": .string("2026-10-05T08:00:00Z"), "metadata": .object(["turnId": .string(turn)])])
        }
        let old = message("old", turn: "previous")
        let user = message("user", role: "user", turn: "current")
        let tool = message("tool", role: "tool", turn: "current")
        XCTAssertNil(ChatPresentation.liveHeadingID(ChatPresentation.displayRows([old, user]), turnID: "current"))
        XCTAssertEqual(ChatPresentation.liveHeadingID(ChatPresentation.displayRows([old, user, tool]), turnID: "current"), "tool")
        let reply = message("reply", turn: "current")
        XCTAssertEqual(ChatPresentation.liveHeadingID(ChatPresentation.displayRows([old, user, tool, reply]), turnID: "current"), "reply")
    }

    func testStreamingBurstPublishesInBatchesWithoutLosingText() async throws {
        let socket = RecoverySocket(); let chat = session([socket]); defer { chat.disconnect() }
        try await chat.connect()
        var publications = 0
        let observation = chat.$messages.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<100 {
            try socket.emit(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("reply"), "delta": .string("字")])]))
        }
        await eventually { chat.messages.first?["content"].string.count == 100 }
        XCTAssertLessThan(publications, 10, "Token bursts must not publish one full transcript per token")
        XCTAssertEqual(chat.messages.first?["content"].string, String(repeating: "字", count: 100))
    }

    func testCompletionFlushesPendingTailBeforeFinalReceipt() async throws {
        let socket = RecoverySocket(); let chat = session([socket]); defer { chat.disconnect() }
        // Calls use the same stream handler but skip HTTP history persistence.
        chat.voiceCallContext = "stream test"
        try await chat.connect()
        try socket.emit(.object(["method": .string("item/reasoning/summaryTextDelta"), "params": .object(["delta": .string("summary")])]))
        try socket.emit(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("reply"), "delta": .string("partial")])]))
        try socket.emit(.object(["method": .string("item/completed"), "params": .object(["item": .object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string("final reply")])])]))
        await eventually { chat.messages.first?["status"].string == "delivered" }
        XCTAssertEqual(chat.messages.first?["content"].string, "final reply")
        XCTAssertEqual(chat.messages.first?["metadata"]["thoughtSummary"].string, "summary")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(chat.messages.first?["content"].string, "final reply")
    }

    func testUsageAttachesToCompletedReplyAndRejectsOtherThreads() async throws {
        let socket = RecoverySocket(); let chat = session([socket]); defer { chat.disconnect() }
        chat.voiceCallContext = "usage fixture"
        try await chat.connect()
        func emit(_ method: String, _ params: JSONValue) throws { try socket.emit(.object(["method": .string(method), "params": params])) }
        try emit("turn/started", .object(["threadId": .string("thread"), "turn": .object(["id": .string("usage-turn")])]))
        let counts: JSONValue = .object(["inputTokens": .number(1000), "cachedInputTokens": .number(800),
            "outputTokens": .number(100), "reasoningOutputTokens": .number(30), "totalTokens": .number(1100)])
        try emit("thread/tokenUsage/updated", .object(["threadId": .string("thread"), "turnId": .string("usage-turn"),
            "tokenUsage": .object(["total": counts, "last": counts])]))
        try emit("item/completed", .object(["threadId": .string("thread"), "turnId": .string("usage-turn"),
            "item": .object(["id": .string("usage-reply"), "type": .string("agentMessage"), "text": .string("Reply")])]))
        try emit("turn/completed", .object(["threadId": .string("thread"), "turn": .object(["id": .string("usage-turn"), "status": .string("completed")])]))
        await eventually { chat.messages.first?["metadata"]["tokenUsage"]["complete"].bool == true }
        XCTAssertEqual(chat.messages.first?["metadata"]["tokenUsage"]["totalTokens"], .number(1100))
        try emit("thread/tokenUsage/updated", .object(["threadId": .string("unrelated"), "turnId": .string("usage-turn"),
            "tokenUsage": .object(["total": .number(999)])]))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(chat.contextUsage["total"], counts)
    }

    func testProtocolBoundaryFlushesTextAndDisconnectCannotLeakToNextChat() async throws {
        let socket = RecoverySocket(); let chat = session([socket]); defer { chat.disconnect() }
        try await chat.connect()
        try socket.emit(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("old-reply"), "delta": .string("tail")])]))
        try socket.emit(.object(["method": .string("item/reasoning/summaryTextDelta"), "params": .object(["delta": .string("thought")])]))
        // A non-delta event must flush synchronously, ahead of completion/persistence.
        try socket.emit(.object(["method": .string("thread/tokenUsage/updated"), "params": .object(["tokenUsage": .object(["total": .number(7)])])]))
        await eventually { chat.contextUsage["total"].number == 7 }
        XCTAssertEqual(chat.messages.first?["content"].string, "tail")
        XCTAssertEqual(chat.thinkingSummary, "thought")
        chat.disconnect()
        chat.newConversation(id: "next-chat")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertTrue(chat.thinkingSummary.isEmpty)
    }

    func testOfflineStateDoesNotSpinWithoutAnAttempt() async {
        let chat = session([RecoverySocket()]); defer { chat.disconnect() }
        chat.networkChanged(available: false)
        do { try await chat.connect() } catch {}
        XCTAssertFalse(chat.reconnecting)
        XCTAssertTrue(chat.connectionNeedsRetry)
    }
    func testRepeatedHeartbeatFailureEventuallyExhaustsBudget() async {
        let socket = RecoverySocket(); socket.pingFailure = true
        let chat = session([socket], heartbeat: 25); defer { chat.disconnect() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertFalse(chat.reconnecting)
    }
    func testWholeAttemptTimeoutIsNotOverwrittenByChildCancellation() async {
        let socket = RecoverySocket(); socket.hangHandshake = true
        let chat = session([socket], timeout: 5, attemptTimeout: 0.1)
        defer { chat.disconnect(); socket.releaseSuspended() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertEqual(chat.recoveryAttempts, 5)
        XCTAssertFalse(chat.reconnecting)
        XCTAssertTrue(chat.connectionIssue?.contains("Timed out") == true)
        XCTAssertFalse(chat.connectionIssue?.contains("error 1") == true)
    }
    func testHungHandshakeHasDeadlineAndActionableRetry() async {
        let socket = RecoverySocket(); socket.hangHandshake = true
        let chat = session([socket], timeout: 0.5); defer { chat.disconnect(); socket.releaseSuspended() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertEqual(chat.connectionStage, .handshake)
        XCTAssertFalse(chat.reconnecting)
        XCTAssertTrue(chat.connectionIssue?.contains("Timed out") == true)
        XCTAssertTrue(socket.packets.isEmpty)
    }
    func testInitializeAndResumeTimeoutsIdentifyTheirStage() async {
        for (method, phase) in [("initialize", ChatConnectionStage.initialize), ("thread/resume", .resume)] {
            let socket = RecoverySocket(); socket.hangMethod = method
            let chat = session([socket], timeout: 0.5)
            do { try await chat.connect() } catch {}
            await eventually { chat.connectionNeedsRetry }
            XCTAssertEqual(chat.connectionStage, phase)
            XCTAssertTrue(chat.connectionIssue?.contains(phase.rawValue) == true)
            XCTAssertFalse(chat.reconnecting)
            chat.disconnect()
        }
    }
    func testInitializedNotificationSendCannotHangRecovery() async {
        let socket = RecoverySocket(); socket.hangInitialized = true
        let chat = session([socket], timeout: 0.5); defer { chat.disconnect(); socket.releaseSuspended() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertEqual(chat.connectionStage, .initialize)
        XCTAssertFalse(chat.reconnecting)
    }
    func testHungHistoryExhaustsAndLateCompletionCannotOverwriteNewConnection() async throws {
        let gate = SuspendedHistory()
        let chat = session([RecoverySocket()], timeout: 0.5, historyReader: { _ in try await gate.read() })
        defer { chat.disconnect(); gate.release(.null) }
        let room = chat.conversationID
        chat.messages = [.object(["id": .string("kept"), "content": .string("keep")])]
        chat.composer.draft = "draft"
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertEqual(chat.connectionStage, .history)
        XCTAssertFalse(chat.reconnecting)
        XCTAssertEqual(chat.recoveryAttempts, 5)
        XCTAssertEqual(chat.composer.draft, "draft")
        // The timed-out HTTP callbacks can finish after the socket was replaced.
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"), endpoint: "wss://invalid.example", threadID: "thread")
        chat.retryConnection()
        await eventually { chat.connectionStage == .ready }
        gate.release(.object(["conversation": .object(["id": .string(room)]), "messages": .array([.object(["id": .string("stale")])])]))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(chat.messages.map(\.id), ["kept"])
        XCTAssertEqual(chat.connectionStage, .ready)
    }
    func testExhaustionSurvivesForegroundRefreshUntilExplicitRetry() async {
        let socket = RecoverySocket(); socket.failInitialize = true
        let chat = session([socket]); defer { chat.disconnect() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        let attempts = socket.packets.count
        chat.sceneChanged(active: true)
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        await chat.loadUsage()
        XCTAssertEqual(socket.packets.count, attempts)
        XCTAssertTrue(chat.connectionNeedsRetry)
        socket.failInitialize = false
        chat.retryConnection()
        await eventually { chat.connectionStage == .ready }
        XCTAssertFalse(chat.reconnecting)
        XCTAssertNil(chat.connectionIssue)
    }
    func testChatAuthenticationFailureIsNotAPIConnectedAndDoesNotLogToken() async {
        let socket = RecoverySocket(); socket.handshakeFailure = true; socket.handshakeStatus = 401
        let chat = session([socket]); defer { chat.disconnect() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertEqual(chat.connectionStage, .handshake)
        XCTAssertTrue(chat.connectionIssue?.contains("401") == true)
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "initialize" })
        let secret = "never-log-this-token"
        let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: "wss://server/?token=" + secret, NSURLErrorFailingURLStringErrorKey: "wss://server/?token=" + secret])
        let diagnostic = ChatSession.connectionDiagnostic(stage: .handshake, failure: error, httpStatus: nil, closeCode: 1006)
        XCTAssertFalse(diagnostic.contains(secret)); XCTAssertFalse(diagnostic.contains("token="))
        XCTAssertTrue(diagnostic.contains("-1001"))
    }
    func testStablePongsResetBudgetOnlyAfterHealthyWindow() async throws {
        let first = RecoverySocket(); first.failInitialize = true
        let second = RecoverySocket()
        let chat = session([first, second], heartbeat: 25, stableInterval: 1)
        defer { chat.disconnect() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionStage == .ready }
        XCTAssertGreaterThan(chat.recoveryAttempts, 0)
        await eventually { second.pingCount > 2 && chat.recoveryAttempts == 0 }
        XCTAssertFalse(chat.connectionNeedsRetry)
    }
    func testResumeRejectionReportsRPCCodeWithoutServerText() async {
        let socket = RecoverySocket(); socket.rejectMethod = "thread/resume"
        let chat = session([socket]); defer { chat.disconnect() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        XCTAssertEqual(chat.connectionStage, .resume)
        XCTAssertTrue(chat.connectionIssue?.contains("-32602") == true)
        XCTAssertFalse(chat.connectionIssue?.contains("never-log-this-token") == true)
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "thread/start" || $0["method"].string == "turn/start" })
    }
    func testLoadingDisconnectRecoversSameThreadWithoutAlert() async {
        let broken = RecoverySocket(); broken.failInitialize = true
        let recovered = RecoverySocket(); let chat = session([broken, recovered]); defer { chat.disconnect() }
        do { try await chat.connect(); XCTFail("Expected failure") } catch {}
        await eventually { recovered.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        XCTAssertEqual(recovered.packets.first { $0["method"].string == "thread/resume" }?["params"]["threadId"].string, "thread")
        XCTAssertNil(chat.error)
        XCTAssertFalse(recovered.packets.contains { $0["method"].string == "thread/start" })
    }
    func testTransientHandshakeFailureStaysProgressWhileRetrying() async {
        let broken = RecoverySocket(); broken.handshakeFailure = true
        let recovered = RecoverySocket()
        var index = 0
        let chat = ChatSession(socketFactory: { _ in
            defer { index += 1 }
            return index == 0 ? broken : recovered
        }, delay: { _ in try await Task.sleep(for: .milliseconds(150)) }, heartbeatInterval: 1000)
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"), endpoint: "wss://invalid.example", threadID: "thread")
        defer { chat.disconnect() }
        do { try await chat.connect(); XCTFail("Expected the first handshake to fail") } catch {}
        let connection = chat.issueDetails.first { $0.id == "connection" }
        XCTAssertTrue(connection?.progress == true)
        XCTAssertFalse(connection?.detail.contains("handshake") == true)
        await eventually { chat.connectionStage == .ready && !chat.reconnecting }
        XCTAssertNil(chat.connectionIssue)
    }
    func testBackgroundPausesOldHeartbeatDeadlineBeforeForegroundProbe() async throws {
        let first = RecoverySocket(), replacement = RecoverySocket()
        first.hangAfterFirstPing = true
        var index = 0
        let chat = ChatSession(socketFactory: { _ in
            defer { index += 1 }
            return index == 0 ? first : replacement
        }, delay: { _ in try await Task.sleep(for: .milliseconds(5)) },
            heartbeatInterval: 0.01, heartbeatTimeout: 0.05)
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"), endpoint: "wss://invalid.example", threadID: "thread")
        defer { chat.disconnect(); first.releaseSuspended() }
        try await chat.connect()
        await eventually { first.pingCount >= 2 }
        chat.sceneChanged(active: false)
        chat.sceneChanged(active: true)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(first.closeCode, .invalid)
        XCTAssertTrue(replacement.packets.isEmpty)
        XCTAssertEqual(chat.recoveryAttempts, 0)
    }
    func testRepeatedShortAppSwitchesReuseSocketWithoutSpendingRecoveryBudget() async throws {
        let first = RecoverySocket(), replacement = RecoverySocket()
        let chat = session([first, replacement], historyReader: { room in
            .object(["conversation": .object(["id": .string(room)]), "messages": .array([])])
        })
        defer { chat.disconnect() }
        chat.composer.draft = "Still typing"
        try await chat.connect()
        for index in 0..<8 {
            chat.sceneChanged(active: false)
            XCTAssertEqual(first.closeCode, .invalid)
            chat.sceneChanged(active: true)
            await eventually { first.pingCount >= index + 2 }
        }
        XCTAssertEqual(first.packets.filter { $0["method"].string == "thread/resume" }.count, 1)
        XCTAssertTrue(replacement.packets.isEmpty)
        XCTAssertEqual(chat.recoveryAttempts, 0)
        XCTAssertFalse(chat.connectionNeedsRetry)
        XCTAssertFalse(chat.reconnecting)
        XCTAssertEqual(chat.composer.draft, "Still typing")
    }
    func testForegroundReconnectsOnlyWhenRetainedSocketIsActuallyDead() async throws {
        let first = RecoverySocket(), replacement = RecoverySocket()
        let chat = session([first, replacement]); defer { chat.disconnect() }
        try await chat.connect()
        chat.sceneChanged(active: false); first.pingFailure = true
        chat.sceneChanged(active: true)
        await eventually { replacement.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        XCTAssertEqual(first.closeCode, .goingAway)
        XCTAssertFalse(chat.connectionNeedsRetry)
        XCTAssertFalse((first.packets + replacement.packets).contains { $0["method"].string == "turn/start" })
    }
    func testForegroundAndNetworkRecoveryPreserveConversationAndMessages() async throws {
        let first = RecoverySocket(), second = RecoverySocket(), third = RecoverySocket()
        let chat = session([first, second, third]); defer { chat.disconnect() }
        let id = chat.conversationID
        chat.composer.draft = "Unsent draft"
        chat.composer.images = [Data([1, 2, 3])]
        chat.messages = [.object(["id": .string("saved"), "content": .string("Keep me")])]
        try await chat.connect()
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        await eventually { first.pingCount >= 2 && !chat.reconnecting }
        XCTAssertTrue(second.packets.isEmpty)
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        XCTAssertTrue(third.packets.isEmpty)
        XCTAssertEqual(chat.conversationID, id); XCTAssertEqual(chat.messages.first?.id, "saved")
        XCTAssertEqual(chat.composer.draft, "Unsent draft")
        XCTAssertEqual(chat.composer.images, [Data([1, 2, 3])])
        XCTAssertNil(chat.error)
    }
    func testForegroundRestoresReplySavedWhilePhoneWasSuspendedWithoutResending() async throws {
        let first = RecoverySocket(), second = RecoverySocket()
        var completed = false
        let chat = session([first, second], historyReader: { room in
            let reply: JSONValue = .object(["id": .string("offline-reply"), "conversationId": .string(room), "role": .string("agent"), "content": .string("Synthetic completed response"), "status": .string("delivered"), "metadata": .object(["threadId": .string("thread"), "turnId": .string("offline-turn"), "phase": .string("final_answer")])])
            return .object(["conversation": .object(["id": .string(room)]), "messages": .array(completed ? [reply] : []), "tombstones": .array([])])
        })
        defer { chat.disconnect() }
        let room = chat.conversationID
        try await chat.connect()
        XCTAssertTrue(chat.messages.isEmpty)
        chat.sceneChanged(active: false); completed = true; chat.sceneChanged(active: true)
        await eventually { chat.messages.contains { $0.id == "offline-reply" } && chat.connectionStage == .ready }
        XCTAssertEqual(chat.conversationID, room)
        XCTAssertEqual(chat.messages.first?["content"].string, "Synthetic completed response")
        XCTAssertFalse((first.packets + second.packets).contains { ["thread/start", "turn/start"].contains($0["method"].string) })
        XCTAssertEqual(first.packets.filter { $0["method"].string == "thread/resume" }.count, 1)
        XCTAssertTrue(second.packets.isEmpty)
    }
    func testExplicitDisconnectPreventsLifecycleReconnect() async throws {
        let first = RecoverySocket(), replacement = RecoverySocket(); let chat = session([first, replacement])
        try await chat.connect(); chat.disconnect()
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(replacement.packets.isEmpty); XCTAssertFalse(chat.reconnecting)
    }
    func testOldReceiveCannotCloseReplacementSocket() async throws {
        let first = RecoverySocket(), second = RecoverySocket(); let chat = session([first, second]); defer { chat.disconnect() }
        first.ignoreCancel = true
        try await chat.connect(); chat.retryConnection()
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        first.fail()
        try await first.emit(.object(["method": .string("turn/completed"), "params": .object([:])]))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(second.closeCode, .invalid); XCTAssertFalse(chat.reconnecting)
    }
    func testHeartbeatFailureReconnects() async throws {
        let first = RecoverySocket(), second = RecoverySocket(); first.pingFailure = true
        let chat = session([first, second], heartbeat: 25); defer { chat.disconnect() }
        try await chat.connect()
        await eventually { first.pingCount > 0 && second.packets.contains { $0["method"].string == "thread/resume" } }
        XCTAssertNil(chat.error)
    }
    func testRetryBudgetIsFinite() async {
        let broken = RecoverySocket(); broken.failInitialize = true
        let chat = session([broken]); defer { chat.disconnect() }
        do { try await chat.connect() } catch {}
        await eventually { chat.connectionNeedsRetry }
        let attempts = broken.packets.count
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(broken.packets.count, attempts)
        XCTAssertEqual(attempts, 6); XCTAssertNil(chat.error)
        XCTAssertEqual(ChatSession.retryDelay(0, jitter: 0.5), 0.5)
        XCTAssertEqual(ChatSession.retryDelay(9, jitter: 1.5), 45)
    }
    func testAcceptedSendWithLostReceiptIsReconciledWithoutResend() async throws {
        let first = RecoverySocket(), second = RecoverySocket(); first.loseReceipt = true
        second.snapshot = .object(["thread": .object(["id": .string("thread"), "turns": .array([.object(["id": .string("turn"), "clientUserMessageId": .string("client"), "status": .string("inProgress"), "items": .array([])])])])])
        let chat = session([first, second]); defer { chat.disconnect() }
        let params: JSONValue = .object(["threadId": .string("thread"), "clientUserMessageId": .string("client")])
        do { _ = try await chat.submitTurn(params); XCTFail("Expected lost receipt") } catch {}
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } && !chat.unconfirmedSend }
        XCTAssertTrue(chat.busy)
        XCTAssertEqual(first.packets.first { $0["method"].string == "turn/start" }?["params"]["clientUserMessageId"].string, "client")
        XCTAssertFalse(second.packets.contains { $0["method"].string == "turn/start" })
    }
    func testMissingReceiptNeverAuthorizesDuplicateSend() async throws {
        let first = RecoverySocket(), second = RecoverySocket(); first.loseReceipt = true
        let chat = session([first, second]); defer { chat.disconnect() }
        let params: JSONValue = .object(["clientUserMessageId": .string("client")])
        do { _ = try await chat.submitTurn(params) } catch {}
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        XCTAssertTrue(chat.unconfirmedSend)
        do { _ = try await chat.submitTurn(params); XCTFail("Must not resend an ambiguous send") } catch {}
        XCTAssertFalse(second.packets.contains { $0["method"].string == "turn/start" })
    }
    func testDisconnectBeforeSendDoesNotSubmitUntilConnected() async {
        let first = RecoverySocket(); first.failInitialize = true
        let second = RecoverySocket(); let chat = session([first, second]); defer { chat.disconnect() }
        let params: JSONValue = .object(["clientUserMessageId": .string("same-client")])
        do { _ = try await chat.submitTurn(params); XCTFail("Expected connect failure") } catch {}
        XCTAssertFalse(chat.unconfirmedSend)
        await eventually { !chat.reconnecting && !second.packets.isEmpty }
        do { _ = try await chat.submitTurn(params) } catch { XCTFail("\(error)") }
        XCTAssertEqual(second.packets.first { $0["method"].string == "turn/start" }?["params"]["clientUserMessageId"].string, "same-client")
    }
    func testExplicitRejectionAllowsSameClientIDToBeRetried() async throws {
        let socket = RecoverySocket(); socket.rejectTurn = true
        let chat = session([socket]); defer { chat.disconnect() }
        let params: JSONValue = .object(["clientUserMessageId": .string("client")])
        do { _ = try await chat.submitTurn(params); XCTFail("Expected rejection") } catch {}
        XCTAssertFalse(chat.unconfirmedSend)
        socket.rejectTurn = false
        _ = try await chat.submitTurn(params)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.map { $0["params"]["clientUserMessageId"].string }, ["client", "client"])
    }
    func testSwitchingConversationCancelsScheduledRecovery() async throws {
        let first = RecoverySocket(), second = RecoverySocket()
        let chat = session([first, second]); defer { chat.disconnect() }
        try await chat.connect(); first.fail()
        await eventually { chat.reconnecting }
        chat.newConversation(id: "different")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(second.packets.isEmpty)
        XCTAssertEqual(chat.conversationID, "different")
        XCTAssertFalse(chat.reconnecting)
    }
    func testPersistedReceiptResolvesLostAcknowledgement() async throws {
        let first = RecoverySocket(), second = RecoverySocket(); first.loseReceipt = true
        var accepted = false
        let chat = session([first, second], historyReader: { id in
            .object(["conversation": .object(["id": .string(id)]), "messages": .array(accepted ? [.object(["id": .string("client"), "role": .string("user"), "status": .string("delivered"), "metadata": .object(["turnId": .string("turn")])])] : [])])
        }); defer { chat.disconnect() }
        do { _ = try await chat.submitTurn(.object(["clientUserMessageId": .string("client")])) } catch {}
        accepted = true
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } && !chat.unconfirmedSend }
        XCTAssertFalse(second.packets.contains { $0["method"].string == "turn/start" })
        XCTAssertEqual(chat.messages.first { $0.id == "client" }?["status"].string, "delivered")
    }
    func testCancelStopsRecoveryButKeepsAmbiguousSendIdentity() async throws {
        let first = RecoverySocket(), second = RecoverySocket(); first.loseReceipt = true
        let chat = session([first, second]); defer { chat.disconnect() }
        do { _ = try await chat.submitTurn(.object(["clientUserMessageId": .string("client")])) } catch {}
        await chat.interrupt()
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        await chat.loadUsage()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(second.packets.isEmpty)
        XCTAssertTrue(chat.unconfirmedSend)
        chat.retryConnection()
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } }
        XCTAssertFalse(second.packets.contains { $0["method"].string == "turn/start" })
    }
    func testResumeMergesCompletedReplyAndPreservesPendingAndTombstones() {
        let saved: [JSONValue] = [.object(["id": .string("reply"), "role": .string("agent"), "content": .string("partial")]), .object(["id": .string("local"), "role": .string("user"), "content": .string("draft send")])]
        let snapshot: JSONValue = .object(["thread": .object(["id": .string("thread"), "turns": .array([.object(["id": .string("turn"), "status": .string("completed"), "items": .array([.object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string("complete")]), .object(["id": .string("deleted"), "type": .string("agentMessage"), "text": .string("gone")])])])])])])
        let merged = ChatRecovery.merge(saved, snapshot: snapshot, conversationID: "c", tombstones: [.object(["itemId": .string("deleted")])])
        XCTAssertEqual(merged.count, 2); XCTAssertEqual(merged[0]["content"].string, "complete")
        XCTAssertEqual(merged[1].id, "local")
        XCTAssertEqual(ChatRecovery.merge(merged, snapshot: snapshot, conversationID: "c", tombstones: [.object(["itemId": .string("deleted")])]), merged)
        XCTAssertNil(ChatRecovery.receipt(for: "local", snapshot: snapshot))
    }
}

private func questionPacket(_ requestID: JSONValue = .number(42)) -> JSONValue {
    .object(["id": requestID, "method": .string("item/tool/requestUserInput"),
        "params": .object(["threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("ask"),
            "questions": .array([.object(["id": .string("format"), "header": .string("Format"),
                "question": .string("Which format do you prefer?"), "isOther": .bool(true),
                "options": .array([.object(["label": .string("Cards"), "description": .string("Compact choices")]),
                                    .object(["label": .string("List"), "description": .string("A plain list")])])])])])])
}

extension ContractTests {
    func testQuestionAnswerProtocolAndValidation() throws {
        let packet = questionPacket()
        XCTAssertThrowsError(try ChatUserInput.answer(packet, selections: [:]))
        let answer = try ChatUserInput.answer(packet, selections: ["format": "Cards", "unrelated": "ignored"])
        XCTAssertEqual(answer["answers"]["format"]["answers"].array, [.string("Cards")])
        XCTAssertEqual(answer["answers"].object.count, 1)
        XCTAssertEqual(try ChatUserInput.answer(packet, selections: ["format": "My choice"])["answers"]["format"]["answers"].array, [.string("My choice")])
        var strict = packet
        var question = strict["params"]["questions"].array[0]
        question["isOther"] = .bool(false)
        strict["params"]["questions"] = .array([question])
        XCTAssertThrowsError(try ChatUserInput.answer(strict, selections: ["format": "Not an option"]))
        strict["params"]["questions"] = .array([question, question])
        XCTAssertThrowsError(try ChatUserInput.questions(strict))
    }
    func testSecretQuestionAnswerIsSentButNotSavedInToolHistory() throws {
        var packet = questionPacket()
        var question = packet["params"]["questions"].array[0]
        question["isSecret"] = .bool(true)
        packet["params"]["questions"] = .array([question])
        XCTAssertEqual(try ChatUserInput.answer(packet, selections: ["format": "private value"])["answers"]["format"]["answers"].array, [.string("private value")])
        XCTAssertEqual(ChatUserInput.savedAnswers(packet, selections: ["format": "private value"])["format"].string, "Private answer")
    }
    func testQuestionIsGroupedAsToolInsteadOfReplyText() {
        let question: JSONValue = .object(["id": .string("q"), "role": .string("system"), "content": .string("Question"),
            "metadata": .object(["blockType": .string("requestUserInput"), "turnId": .string("turn"),
                "userInput": .object(["questions": questionPacket()["params"]["questions"]])])])
        let reply: JSONValue = .object(["id": .string("a"), "role": .string("agent"), "content": .string("Here is the result"),
            "metadata": .object(["turnId": .string("turn")])])
        let rows = ChatPresentation.displayRows([question, reply])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].messages.first?.id, "a")
        XCTAssertEqual(rows[0].activities.first?.id, "q")
        XCTAssertTrue(ChatPresentation.isActivity(question))
    }
}

extension ChatConnectionRecoveryTests {
    func testQuestionRequestRespondsWithOriginalNumericIDAndDoesNotCreateUserProse() async throws {
        let socket = RecoverySocket()
        let chat = session([socket]); defer { chat.disconnect() }
        var saved: [JSONValue] = []
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"),
                                 endpoint: "wss://invalid.example", threadID: "thread", questionWriter: { saved.append($0) })
        try await chat.connect()
        try socket.emit(questionPacket())
        await eventually { chat.userInputRequests.count == 1 }
        try socket.emit(questionPacket())
        await Task.yield()
        let request = try XCTUnwrap(chat.userInputRequests.first)
        let result = await chat.resolveQuestion(request.id, selections: ["format": "Cards"])
        XCTAssertTrue(result)
        XCTAssertTrue(chat.userInputRequests.isEmpty)
        let response = socket.packets.last { $0["id"] == .number(42) && $0["result"]["answers"] != .null }
        XCTAssertEqual(response?["result"]["answers"]["format"]["answers"].array, [.string("Cards")])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?["metadata"]["userInput"]["status"].string, "answered")
        XCTAssertFalse(chat.messages.contains { ChatPresentation.isUser($0) })
    }
    func testResolvedAndDisconnectedQuestionsCannotBeAnsweredLater() async throws {
        let socket = RecoverySocket()
        let chat = session([socket]); defer { chat.disconnect() }
        try await chat.connect()
        try socket.emit(questionPacket())
        await eventually { !chat.userInputRequests.isEmpty }
        let stale = try XCTUnwrap(chat.userInputRequests.first)
        try socket.emit(.object(["method": .string("serverRequest/resolved"),
                                "params": .object(["threadId": .string("thread"), "requestId": .number(42)])]))
        await eventually { chat.userInputRequests.isEmpty }
        let rejected = await chat.resolveQuestion(stale.id, selections: ["format": "Cards"])
        XCTAssertFalse(rejected)
        try socket.emit(questionPacket(.string("next")))
        await eventually { !chat.userInputRequests.isEmpty }
        let disconnected = try XCTUnwrap(chat.userInputRequests.first)
        chat.disconnect()
        let later = await chat.resolveQuestion(disconnected.id, selections: ["format": "Cards"])
        XCTAssertFalse(later)
        XCTAssertTrue(chat.userInputRequests.isEmpty)
    }
}

extension ChatConnectionRecoveryTests {
    func testQuestionCancellationAdvancesQueueAndTurnCompletionExpiresRemainingCard() async throws {
        let socket = RecoverySocket()
        let chat = session([socket]); defer { chat.disconnect() }
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"),
                                 endpoint: "wss://invalid.example", threadID: "thread", questionWriter: { _ in })
        try await chat.connect()
        try socket.emit(.object(["id": .string("expired-rpc"), "result": .object([:])]))
        try socket.emit(questionPacket())
        try socket.emit(questionPacket(.string("second")))
        await eventually { chat.userInputRequests.count == 2 }
        XCTAssertFalse(socket.packets.contains { $0["id"] == .string("expired-rpc") })
        let first = try XCTUnwrap(chat.userInputRequests.first)
        let cancelled = await chat.resolveQuestion(first.id)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(chat.userInputRequests.first?.packet["id"], .string("second"))
        let response = socket.packets.last { $0["id"] == .number(42) && $0["result"]["answers"] != .null }
        XCTAssertEqual(response?["result"]["answers"], .object([:]))
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object(["turn": .object(["id": .string("turn")])])]))
        await eventually { chat.userInputRequests.isEmpty }
    }
}

private func asyncQuestionEvent() -> JSONValue {
    .object(["method": .string("item/completed"), "params": .object(["threadId": .string("thread"), "turnId": .string("turn"),
        "item": .object(["type": .string("agentMessage"), "id": .string("call_probe"), "phase": .string("final_answer"),
            "text": .string("Do you prefer tea or coffee?\n- Tea\n- Coffee"), "delivery": .string("async"),
            "questions": .array([.object(["title": .string("Do you prefer tea or coffee?"), "options": .array([.string("Tea"), .string("Coffee")])])])])])])
}

extension ChatConnectionRecoveryTests {
    func testLiveAsyncQuestionShapeSurvivesTurnAndReturnsCorrelatedAnswer() async throws {
        let socket = RecoverySocket()
        let chat = session([socket]); defer { chat.disconnect() }
        var saved: [JSONValue] = []
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"),
                                 endpoint: "wss://invalid.example", threadID: "thread", questionWriter: { saved.append($0) })
        try await chat.connect()
        try socket.emit(asyncQuestionEvent())
        await eventually { saved.count == 1 }
        try socket.emit(asyncQuestionEvent()) // Duplicate delivery must not create another card.
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object(["turn": .object(["id": .string("turn")])])]))
        await Task.yield()
        let request = try XCTUnwrap(chat.userInputRequests.first)
        XCTAssertEqual(chat.userInputRequests.count, 1)
        XCTAssertEqual(chat.messages.first?["metadata"]["userInput"]["status"].string, "waiting")
        XCTAssertEqual(chat.messages.first?["content"].string, "Question")
        XCTAssertTrue(ChatPresentation.isActivity(try XCTUnwrap(chat.messages.first)))
        let sent = await chat.resolveQuestion(request.id, selections: ["0": "Coffee"])
        XCTAssertTrue(sent)
        let turn = try XCTUnwrap(socket.packets.last { $0["method"].string == "turn/start" })
        let reply = turn["params"]["input"].array[0]["text"].string
        XCTAssertTrue(reply.hasPrefix("<send_user_message_question_reply>"))
        let json = reply.replacingOccurrences(of: "<send_user_message_question_reply>", with: "").replacingOccurrences(of: "</send_user_message_question_reply>", with: "")
        let answers = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).array
        XCTAssertEqual(answers[0]["questionItemId"].string, "[\"request_user_input_async\",\"call_probe\",0]")
        XCTAssertEqual(answers[0]["answer"].string, "Coffee")
        XCTAssertFalse(chat.messages.contains { ChatPresentation.isUser($0) })
        XCTAssertEqual(saved.last?["metadata"]["userInput"]["status"].string, "answered")
        XCTAssertTrue(chat.userInputRequests.isEmpty)
        XCTAssertFalse(socket.packets.contains { $0["id"] == .string("call_probe") }) // Async messages are not JSON-RPC requests.
    }
    func testAsyncCancelDoesNotStartTurnAndMalformedQuestionCannotShowCard() async throws {
        let socket = RecoverySocket()
        let chat = session([socket]); defer { chat.disconnect() }
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "test"),
                                 endpoint: "wss://invalid.example", threadID: "thread", questionWriter: { _ in })
        try await chat.connect()
        var malformed = asyncQuestionEvent()
        var item = malformed["params"]["item"]
        item["questions"] = .array([.object(["title": .string(""), "options": .array([.string("Tea")])])])
        malformed["params"]["item"] = item
        try socket.emit(malformed)
        await eventually { chat.error != nil }
        XCTAssertTrue(chat.userInputRequests.isEmpty)
        try socket.emit(asyncQuestionEvent())
        await eventually { chat.userInputRequests.count == 1 }
        let cancelled = await chat.resolveQuestion(try XCTUnwrap(chat.userInputRequests.first).id)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "turn/start" })
        XCTAssertEqual(chat.messages.first?["metadata"]["userInput"]["status"].string, "cancelled")
    }
    func testNonBlockingServerQuestionAlsoSurvivesTurnCompletion() async throws {
        let socket = RecoverySocket()
        let chat = session([socket]); defer { chat.disconnect() }
        try await chat.connect()
        var packet = questionPacket()
        packet["params"]["isBlocking"] = .bool(false)
        try socket.emit(packet)
        await eventually { chat.userInputRequests.count == 1 }
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object(["turn": .object(["id": .string("turn")])])]))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(chat.userInputRequests.count, 1)
    }
}

private final class BubblePersistenceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storage: [JSONValue] = []
    static var records: [JSONValue] { lock.lock(); defer { lock.unlock() }; return storage }
    static func reset() { lock.lock(); storage = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bubble-test.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
        }
        let record = (try? JSONDecoder().decode(JSONValue.self, from: bytes)) ?? .null
        if request.httpMethod == "POST", record != .null {
            Self.lock.lock(); Self.storage.append(record); Self.lock.unlock()
        }
        var status = 200
        var result: JSONValue = .object([:])
        if record["name"].string == "sticker_send" {
            if record["turnId"].string.isEmpty || record["conversationId"].string.isEmpty {
                status = 400
                result = .object(["error": .string("The sticker must belong to the current conversation turn.")])
            } else {
                result = .object(["result": .object(["stickerMessage": .object([
                    "assetId": .string("fixture-sticker"), "url": .string("https://bubble-test.example/sticker.png"), "mimeType": .string("image/png")])])])
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(result)); client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension ChatConnectionRecoveryTests {
    func testBubbleToolPersistsVerifiedQuoteAndRejectsFabricatedQuote() async throws {
        BubblePersistenceProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BubblePersistenceProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000)
        chat.configureConnection(api: APIClient(baseURL: "https://bubble-test.example", historyURL: "https://bubble-test.example", token: "synthetic", requestSession: http), endpoint: "wss://bubble-test.example", threadID: "thread")
        defer { chat.disconnect() }
        try await chat.connect()
        let original: JSONValue = .object(["id": .string("source"), "role": .string("user"), "content": .string("这句我想收藏起来。"), "conversationId": .string(chat.conversationID)])
        chat.messages = [original]
        func packet(_ id: String, quote: String) -> JSONValue {
            .object(["id": .string(id), "method": .string("item/tool/call"), "params": .object([
                "name": .string("send_native_bubbles"), "callId": .string(id), "arguments": .object([
                    "bubbles": .array([.object(["text": .string("那就替你留着。"), "replyToMessageId": .string("source"), "quote": .string(quote)]),
                                       .object(["text": .string("以后看到它，就想起今天。")])])])])])
        }
        try socket.emit(packet("good", quote: "这句我想收藏起来。"))
        await eventually { socket.packets.contains { $0["id"].string == "good" && $0["result"] != .null } }
        XCTAssertEqual(socket.packets.last { $0["id"].string == "good" }?["result"]["success"], .bool(true))
        let saved = try XCTUnwrap(BubblePersistenceProtocol.records.first { !$0["metadata"]["bubbles"].array.isEmpty })
        XCTAssertEqual(saved["metadata"]["bubbles"].array.count, 2)
        XCTAssertEqual(saved["metadata"]["bubbles"].array[0]["replyTo"]["messageId"].string, "source")
        XCTAssertEqual(saved["metadata"]["bubbles"].array[0]["replyTo"]["partId"].string, "source#text-0")
        let restored = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(ChatBubbles.textParts(restored).map { $0["content"].string }, ["那就替你留着。", "以后看到它，就想起今天。"])
        try socket.emit(packet("bad", quote: "这句话没有说过。"))
        await eventually { socket.packets.contains { $0["id"].string == "bad" && $0["result"] != .null } }
        XCTAssertEqual(socket.packets.last { $0["id"].string == "bad" }?["result"]["success"], .bool(false))
        XCTAssertEqual(chat.messages.filter { !$0["metadata"]["bubbles"].array.isEmpty }.count, 1)
        XCTAssertEqual(BubblePersistenceProtocol.records.filter { !$0["metadata"]["bubbles"].array.isEmpty }.count, 1)
    }
}


extension ChatConnectionRecoveryTests {
    func testStickerDeliveryUsesRequestTurnEvenWithoutActiveSessionTurn() async throws {
        BubblePersistenceProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BubblePersistenceProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000)
        chat.configureConnection(api: APIClient(baseURL: "https://bubble-test.example", historyURL: "https://bubble-test.example", token: "synthetic", requestSession: http), endpoint: "wss://bubble-test.example", threadID: "thread")
        defer { chat.disconnect() }
        try await chat.connect()
        func packet(_ id: String, turn: String?, thread: String = "thread") -> JSONValue {
            var params: JSONValue = .object(["name": .string("sticker_send"), "callId": .string(id), "threadId": .string(thread),
                                            "arguments": .object(["assetId": .string("fixture-sticker")])])
            if let turn { params["turnId"] = .string(turn) }
            return .object(["id": .string(id), "method": .string("item/tool/call"), "params": params])
        }
        // Reconnected client has no active turn; the request still identifies its origin.
        XCTAssertFalse(chat.busy)
        try socket.emit(packet("after-reconnect", turn: "request-turn"))
        await eventually { socket.packets.contains { $0["id"].string == "after-reconnect" && $0["result"] != .null } }
        XCTAssertEqual(socket.packets.last { $0["id"].string == "after-reconnect" }?["result"]["success"], .bool(true))
        let forwarded = try XCTUnwrap(BubblePersistenceProtocol.records.first { $0["name"].string == "sticker_send" })
        XCTAssertEqual(forwarded["turnId"].string, "request-turn")
        XCTAssertEqual(forwarded["threadId"].string, "thread")
        XCTAssertEqual(forwarded["conversationId"].string, chat.conversationID)
        let saved = try XCTUnwrap(BubblePersistenceProtocol.records.first { $0["type"].string == "sticker" })
        XCTAssertEqual(saved["metadata"]["turnId"].string, "request-turn")
        XCTAssertEqual(chat.messages.first { $0.id == saved.id }?["metadata"]["sticker"]["assetId"].string, "fixture-sticker")

        try socket.emit(.object(["method": .string("turn/started"), "params": .object(["turn": .object(["id": .string("session-turn")])])]))
        await eventually { chat.busy }
        try socket.emit(packet("explicit-turn", turn: "another-request-turn"))
        await eventually { socket.packets.contains { $0["id"].string == "explicit-turn" && $0["result"] != .null } }
        XCTAssertEqual(BubblePersistenceProtocol.records.last { $0["name"].string == "sticker_send" }?["turnId"].string, "another-request-turn")
        // Older tool requests without a turn use the captured session turn.
        try socket.emit(packet("legacy", turn: nil))
        await eventually { socket.packets.contains { $0["id"].string == "legacy" && $0["result"] != .null } }
        XCTAssertEqual(BubblePersistenceProtocol.records.last { $0["name"].string == "sticker_send" }?["turnId"].string, "session-turn")
        let count = BubblePersistenceProtocol.records.count
        try socket.emit(packet("wrong-thread", turn: "other-turn", thread: "other-thread"))
        await eventually { socket.packets.contains { $0["id"].string == "wrong-thread" && $0["result"] != .null } }
        XCTAssertEqual(socket.packets.last { $0["id"].string == "wrong-thread" }?["result"]["success"], .bool(false))
        XCTAssertEqual(BubblePersistenceProtocol.records.count, count)
    }
}

final class ChatRecentCacheTests: XCTestCase {
    func testPreviewCacheIsBoundedAccountScopedAndRemovable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = APIClient(baseURL: "https://cache.example", historyURL: "https://history.example", token: "synthetic-a")
        var other = api; other.token = "synthetic-b"
        var otherService = api; otherService.historyURL = "https://other.example"
        var messages: [JSONValue] = (0..<130).map { .object(["id": .string("m-\($0)"), "content": .string("fixture"), "status": .string("delivered")]) }
        messages.append(.object(["id": .string("pending"), "status": .string("pending")]))
        messages.append(.object(["id": .string("streaming"), "status": .string("streaming")]))
        messages.append(.object(["id": .string("failed"), "status": .string("error")]))
        ChatRecentCache.save(api: api, id: "room", messages: messages, root: root)
        ChatRecentCache.rememberMain(api: api, id: "room", root: root)
        XCTAssertEqual(ChatRecentCache.load(api: api, id: "room", root: root)?["messages"].array.count, 100)
        XCTAssertEqual(ChatRecentCache.load(api: api, id: "room", root: root)?["messages"].array.first?.id, "m-30")
        XCTAssertNil(ChatRecentCache.load(api: other, id: "room", root: root))
        XCTAssertNil(ChatRecentCache.load(api: otherService, id: "room", root: root))
        XCTAssertNil(ChatRecentCache.load(api: api, id: "other-room", root: root))
        XCTAssertEqual(ChatRecentCache.mainID(api: api, root: root), "room")
        ChatRecentCache.remove(api: api, id: "room", root: root)
        XCTAssertNil(ChatRecentCache.mainID(api: api, root: root))
        XCTAssertNil(ChatRecentCache.load(api: api, id: "room", root: root))
    }
    @MainActor func testCachedPreviewCannotSendUntilValidatedAndFreshHistoryReplacesIt() async throws {
        let api = APIClient(baseURL: "https://history-pagination.example", historyURL: "https://history-pagination.example", token: "cache-test-" + UUID().uuidString)
        defer { if let dir = ChatRecentCache.directory(api: api) { try? FileManager.default.removeItem(at: dir) } }
        ChatRecentCache.save(api: api, id: "pagination-room", messages: [.object(["id": .string("stale"), "role": .string("user"), "content": .string("cached fixture"), "status": .string("delivered")])])
        let chat = ChatSession()
        chat.configureConnection(api: api, endpoint: "wss://invalid.example")
        XCTAssertTrue(chat.previewConversation("pagination-room"))
        XCTAssertTrue(chat.showingCachedHistory)
        XCTAssertEqual(chat.messages.first?.id, "stale")
        let sent = await chat.send("must not send from unvalidated cache")
        XCTAssertFalse(sent)
        ChatHistoryPaginationProtocol.reset()
        URLProtocol.registerClass(ChatHistoryPaginationProtocol.self)
        defer { URLProtocol.unregisterClass(ChatHistoryPaginationProtocol.self) }
        let opened = await chat.open(.object(["id": .string("pagination-room")]))
        XCTAssertTrue(opened)
        XCTAssertFalse(chat.showingCachedHistory)
        XCTAssertEqual(chat.messages.map(\.id), ["latest"])
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestCount, 1)
        XCTAssertEqual(ChatRecentCache.load(api: api, id: "pagination-room")?["messages"].array.map(\.id), ["latest"], "Fresh iPhone history must replace stale disk previews")
        chat.disconnect()
    }
}

@MainActor final class DesireEmotionTests: XCTestCase {
    func testToolCompletionDoesNotInventConfirmedWrites() {
        XCTAssertEqual(DesireEmotion.activityOutcome(status: "completed", receipt: .null), "unconfirmed")
        XCTAssertEqual(DesireEmotion.activityOutcome(status: "completed", receipt: .object(["pending": .bool(true), "saved": .bool(true)])), "unconfirmed")
        XCTAssertEqual(DesireEmotion.activityOutcome(status: "completed", receipt: .object(["saved": .bool(true)])), "confirmed")
        XCTAssertEqual(DesireEmotion.activityOutcome(status: "completed", receipt: .object(["success": .bool(false)])), "failed")
        XCTAssertEqual(DesireEmotion.activityOutcome(status: "failed", receipt: .object(["saved": .bool(true)])), "failed")
    }
    func testToolEvidenceIsBoundedAndExcludesConnectionSecrets() {
        let receipt: JSONValue = .object(["title": .string("实际读到的内容"), "api_key": .string("secret-fixture"), "nested": .object(["deviceToken": .string("secret-fixture"), "summary": .string(String(repeating: "内容", count: 3000))])])
        let text = DesireEmotion.receiptText(receipt)
        XCTAssertTrue(text.contains("实际读到的内容"))
        XCTAssertFalse(text.contains("secret-fixture"))
        XCTAssertLessThanOrEqual(text.count, 3000)
    }
    func testAttachedStateNeverAppearsInStreamedBubbles() {
        let marker = "<vesper-emotion>"
        for count in 2...marker.count {
            XCTAssertEqual(ChatBubbles.texts("我在这里。\n\n" + String(marker.prefix(count))), ["我在这里。"])
        }
        XCTAssertEqual(ChatBubbles.texts("我在这里。<vesper-emotion>{broken json"), ["我在这里。"])
        XCTAssertEqual(ChatBubbles.texts("<vesper-emotion>{internal}"), [])
    }
    func testEightIndependentValuesAreValidatedAndNotRenamedLegacyFields() {
        var values: [String: JSONValue] = [:]
        for (key, _) in DesireEmotion.fields { values[key] = .number(70) }
        var candidate: JSONValue = .object(["values": .object(values), "reason": .string("真实近期对话。"), "unresolved": .string("")])
        XCTAssertTrue(DesireEmotion.valid(candidate))
        candidate["values"]["joy"] = .number(101)
        XCTAssertFalse(DesireEmotion.valid(candidate))
        candidate["values"] = .object(["longing": .number(70)])
        XCTAssertFalse(DesireEmotion.valid(candidate))
    }
    func testCompletedCandidateIsSeparateFromOrdinaryReply() {
        let values = Dictionary(uniqueKeysWithValues: DesireEmotion.fields.map { ($0.0, JSONValue.number(30)) })
        let value: JSONValue = .object(["values": .object(values), "reason": .string("聊天后的状态。"), "unresolved": .string("")])
        let text = "晚点见。\n\n<vesper-emotion>" + value.pretty + "</vesper-emotion>"
        XCTAssertEqual(DesireEmotion.attached(text), value)
        XCTAssertEqual(ChatBubbles.texts(text), ["晚点见。"])
        XCTAssertNil(DesireEmotion.attached("<vesper-emotion>{incomplete"))
        let user: JSONValue = .object(["id": .string("user"), "role": .string("user"), "content": .string("请解释 <vesper-emotion>")])
        XCTAssertEqual(ChatBubbles.textParts(user).first?["content"].string, "请解释 <vesper-emotion>")
    }
}

@MainActor final class ChatSpaceIndexTests: XCTestCase {
    func testBothSendersPaginationCachingAndFailedRefreshPreserveFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("space.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let api = APIClient(baseURL: "https://fixture.example", historyURL: "https://fixture.example/history", token: "fixture")
        var revision = "1", calls = [String](), fail = false, deleted = false
        func message(_ id: String, _ role: String, _ name: String) -> JSONValue {
            .object(["id": .string(id), "role": .string(role), "createdAt": .string("2026-10-11T10:00:00Z"),
                     "metadata": .object(["attachments": .array([.object(["name": .string(name), "url": .string("https://fixture.example/media/" + id)])])])])
        }
        let index = ChatSpaceIndex(api: api, cacheURL: file) { path in
            calls.append(path)
            let room: JSONValue = .object(["id": .string("room-with-hyphens"), "title": .string("Chat"), "updatedAt": .string(revision)])
            if path == "/conversations" { return .object(["conversations": .array(deleted ? [] : [room])]) }
            if fail { throw ServiceError(message: "Offline") }
            XCTAssertTrue(path.hasPrefix("/conversations/room-with-hyphens?"))
            let older = path.contains("before=")
            return .object(["conversation": room, "messages": .array(older ? [message("b", "assistant", "photo.png"), message("removed", "assistant", "gone.pdf")] : [message("a", "user", "notes.pdf")]),
                            "tombstones": .array([.object(["messageId": .string("removed")])]),
                            "hasMore": .bool(!older), "before": .string(older ? "" : "older")])
        }
        await index.refresh()
        XCTAssertEqual(index.items.count, 2)
        XCTAssertEqual(Set(index.items.map(\.kind)), ["Files", "Images"])
        XCTAssertEqual(index.items.filter(\.fromVera).count, 1)
        XCTAssertEqual(calls.count, 3)
        await index.refresh(); XCTAssertEqual(calls.count, 4, "Unchanged rooms must not page history again")
        let cached = ChatSpaceIndex(api: api, cacheURL: file)
        XCTAssertEqual(cached.items, index.items)
        revision = "2"; fail = true
        await index.refresh(); XCTAssertNotNil(index.error); XCTAssertEqual(index.items.count, 2)
        deleted = true
        await index.refresh(); XCTAssertTrue(index.items.isEmpty)
    }
    func testProjectSourcesOnlyScanTheirMemberConversations() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("space.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let api = APIClient(baseURL: "https://fixture.example", historyURL: "https://fixture.example/history", token: "fixture")
        var paths: [String] = []
        let room: JSONValue = .object(["id": .string("member"), "updatedAt": .string("1")])
        let index = ChatSpaceIndex(api: api, cacheURL: file) { path in
            paths.append(path)
            if path == "/conversations" { return .object(["conversations": .array([room, .object(["id": .string("outside")])])]) }
            return .object(["conversation": room, "messages": .array([]), "hasMore": .bool(false)])
        }
        await index.refresh(conversationIDs: ["member"])
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.last?.hasPrefix("/conversations/member?") == true)
        XCTAssertFalse(paths.contains { $0.contains("outside") })
        paths.removeAll()
        await index.refresh(force: true, conversationIDs: [])
        XCTAssertEqual(paths, ["/conversations"])
    }
    func testInvalidAttachmentLinksAreExcluded() {
        let room: JSONValue = .object(["id": .string("r")])
        let messages: [JSONValue] = [.object(["id": .string("m"), "metadata": .object(["attachments": .array([
            .object(["url": .string("file:///etc/passwd")]), .object(["url": .string("https://user:password@example.com/a")])
        ])])])]
        XCTAssertTrue(ChatSpaceItem.extract(messages: messages, room: room, tombstones: []).isEmpty)
    }
}

extension ChatConnectionRecoveryTests {
    func testCollectedMessagesWaitPersistAndSubmitOneOrderedTurn() async throws {
        let previous = UserDefaults.standard.object(forKey: "chatReplyMode")
        defer { UserDefaults.standard.set(previous, forKey: "chatReplyMode") }
        SendPreparationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: configuration), socket = RecoverySocket()
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        let room = chat.conversationID
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel(); try? ChatQueuedStore.save([], api: api, conversationID: room) }
        chat.model = ""; chat.effort = ""; chat.replyMode = .collected
        var accepted = 0
        let first = await chat.send("先等我说完", onAccepted: { accepted += 1 })
        let second = await chat.send("这是第二条", music: .object(["title": .string("Fixture song")]), onAccepted: { accepted += 1 })
        XCTAssertTrue(first && second); XCTAssertEqual(accepted, 2)
        XCTAssertTrue(socket.packets.isEmpty); XCTAssertTrue(SendPreparationProtocol.captured.isEmpty)
        XCTAssertFalse(chat.busy); XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(try ChatQueuedStore.load(api: api, conversationID: room).map(\.text), ["先等我说完", "这是第二条"])
        chat.newConversation(id: "another-room")
        XCTAssertTrue(chat.queuedMessages.isEmpty)
        chat.newConversation(id: room)
        XCTAssertEqual(chat.queuedMessages.count, 2)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.replyMode = .immediate
        XCTAssertTrue(socket.packets.isEmpty, "Changing mode must not submit existing drafts")
        let third = await chat.send("最后补充一句")
        XCTAssertTrue(third); XCTAssertEqual(chat.queuedMessages.count, 3)
        let sent = await chat.sendCollectedMessages()
        XCTAssertTrue(sent)
        XCTAssertTrue(chat.queuedMessages.isEmpty)
        XCTAssertTrue(try ChatQueuedStore.load(api: api, conversationID: room).isEmpty)
        let turns = socket.packets.filter { $0["method"].string == "turn/start" }
        XCTAssertEqual(turns.count, 1)
        let input = try XCTUnwrap(turns.first)["params"]["input"].array.map { $0["text"].string }.joined()
        XCTAssertLessThan(try XCTUnwrap(input.range(of: "先等我说完")).lowerBound, try XCTUnwrap(input.range(of: "这是第二条")).lowerBound)
        XCTAssertTrue(input.contains("Fixture song")); XCTAssertTrue(input.contains("最后补充一句"))
        let user = try XCTUnwrap(chat.messages.first { $0["role"].string == "user" })
        XCTAssertEqual(ChatBubbles.textParts(user).map { $0["content"].string }, ["先等我说完", "这是第二条", "最后补充一句"])
        XCTAssertTrue(ChatBubbles.textParts(user).allSatisfy { $0["metadata"]["sourceMessageId"].string == user.id })
        let again = await chat.sendCollectedMessages()
        XCTAssertFalse(again); XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 1)
        chat.busy = false
        let immediate = await chat.send("现在即时回复")
        XCTAssertTrue(immediate); XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 2)
    }

    func testCollectedRejectionRestoresQueueAndLostReceiptDoesNotResubmit() async throws {
        let previous = UserDefaults.standard.object(forKey: "chatReplyMode")
        defer { UserDefaults.standard.set(previous, forKey: "chatReplyMode") }
        SendPreparationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: configuration), socket = RecoverySocket()
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, delay: { _ in try await Task.sleep(for: .seconds(60)) }, heartbeatInterval: 1000, sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel(); try? ChatQueuedStore.save([], api: api, conversationID: chat.conversationID) }
        chat.model = ""; chat.effort = ""; chat.replyMode = .collected
        let queued = await chat.send("请一起回复")
        XCTAssertTrue(queued)
        socket.rejectTurn = true
        let rejected = await chat.sendCollectedMessages()
        XCTAssertFalse(rejected); XCTAssertFalse(chat.busy)
        XCTAssertEqual(chat.queuedMessages.count, 1); XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(try ChatQueuedStore.load(api: api, conversationID: chat.conversationID).count, 1)
        socket.rejectTurn = false; socket.loseReceipt = true
        let ambiguous = await chat.sendCollectedMessages()
        XCTAssertFalse(ambiguous); XCTAssertTrue(chat.unconfirmedSend)
        XCTAssertTrue(chat.queuedMessages.isEmpty)
        XCTAssertEqual(try outbox.pending(api, conversationID: chat.conversationID).count, 1)
        let retry = await chat.sendCollectedMessages()
        XCTAssertFalse(retry)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 2)
    }

    func testCollectedAttachmentsPersistAndStayScopedToBackendAndAccount() throws {
        let api = APIClient(baseURL: "https://batch.example", historyURL: "https://batch.example/history", token: UUID().uuidString)
        let room = UUID().uuidString
        defer { try? ChatQueuedStore.save([], api: api, conversationID: room) }
        let image = Data([1, 2, 3]), file = ChatFile(name: "voice.m4a", mime: "audio/mp4", data: Data([4, 5]), transcript: "一句语音", duration: 2)
        let entry = ChatQueuedMessage(text: "带附件", images: [image], files: [file], replyTo: .object(["messageId": .string("quote")]))
        try ChatQueuedStore.save([entry], api: api, conversationID: room)
        let restored = try XCTUnwrap(ChatQueuedStore.load(api: api, conversationID: room).first)
        XCTAssertEqual(restored.images, [image]); XCTAssertEqual(restored.files.first?.data, file.data)
        XCTAssertEqual(restored.files.first?.transcript, "一句语音"); XCTAssertEqual(restored.replyTo?["messageId"].string, "quote")
        var other = api; other.baseURL = "https://mac.example"
        XCTAssertTrue(try ChatQueuedStore.load(api: other, conversationID: room).isEmpty)
        other = api; other.token = UUID().uuidString
        XCTAssertTrue(try ChatQueuedStore.load(api: other, conversationID: room).isEmpty)
        XCTAssertTrue(try ChatQueuedStore.load(api: api, conversationID: "other-room").isEmpty)
    }
}


extension ChatConnectionRecoveryTests {
    func testCollectedMixedAttachmentsKeepTheirMessageAndOneModelTurn() async throws {
        let previous = UserDefaults.standard.object(forKey: "chatReplyMode")
        URLProtocol.registerClass(SendPreparationProtocol.self)
        defer { URLProtocol.unregisterClass(SendPreparationProtocol.self); UserDefaults.standard.set(previous, forKey: "chatReplyMode") }
        SendPreparationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: configuration), socket = RecoverySocket()
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel(); try? ChatQueuedStore.save([], api: api, conversationID: chat.conversationID) }
        chat.model = ""; chat.effort = ""; chat.replyMode = .collected
        _ = await chat.send("看这张图", images: [Data([1, 2, 3])])
        _ = await chat.send("再看文件", files: [ChatFile(name: "note.txt", mime: "text/plain", data: Data("文件内容".utf8))])
        _ = await chat.send("第二张图", images: [Data([4, 5, 6])])
        XCTAssertTrue(SendPreparationProtocol.captured.isEmpty)
        let sent = await chat.sendCollectedMessages()
        XCTAssertTrue(sent, chat.error ?? "")
        let turns = socket.packets.filter { $0["method"].string == "turn/start" }
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?["params"]["input"].array.filter { $0["type"].string == "image" }.count, 2)
        let parent = try XCTUnwrap(chat.messages.first { $0["role"].string == "user" })
        let children = ChatBubbles.batchOriginals(parent)
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(children.map { $0["metadata"]["attachments"].array.first?["type"].string ?? "" }, ["image/jpeg", "text/plain", "image/jpeg"])
        XCTAssertEqual(children.map { $0["metadata"]["batchAttachmentIndices"].array.first?.number ?? -1 }, [0, 2, 1])
        XCTAssertEqual(Set(parent["metadata"]["attachments"].array.map { $0["url"].string }).count, 3)
        XCTAssertEqual(SendPreparationProtocol.captured.filter { $0.url?.path == "/api/media" }.count, 3)
    }
}

final class ChatMessageDeletionTests: XCTestCase {
    private func message() -> JSONValue {
        .object(["id": .string("reply"), "role": .string("agent"), "content": .string("第一句。\n\n第二句。"), "status": .string("delivered"),
                 "metadata": .object(["itemId": .string("reply"), "threadId": .string("thread"), "turnId": .string("turn")])])
    }
    func testDeletingOneBubblePreservesSiblingAndDoesNotReturnFromSnapshot() throws {
        let original = message(), parts = ChatBubbles.textParts(original)
        XCTAssertEqual(parts.count, 2)
        let updated = try XCTUnwrap(ChatMessageDeletion.removing(parts[0], from: original))
        XCTAssertEqual(ChatBubbles.textParts(updated).map { $0["content"].string }, ["第二句。"])
        XCTAssertEqual(ChatBubbles.textParts(updated).first?.id, parts[1].id, "Surviving bubbles must keep their quote/favorite identity")
        let snapshot: JSONValue = .object(["thread": .object(["id": .string("thread"), "turns": .array([
            .object(["id": .string("turn"), "status": .string("completed"), "items": .array([
                .object(["id": .string("reply"), "type": .string("agentMessage"), "text": original["content"]])])])])])])
        let recovered = ChatRecovery.merge([updated], snapshot: snapshot, conversationID: "room", tombstones: [])
        XCTAssertEqual(recovered.first?["content"], updated["content"])
        XCTAssertNil(try ChatMessageDeletion.removing(ChatBubbles.textParts(updated)[0], from: updated))
    }
    func testAttachmentDeletionPreservesOtherFilesAndTextAndLastTextLeavesOnlyAttachment() throws {
        var original = message()
        let a: JSONValue = .object(["url": .string("https://example.com/a.pdf"), "type": .string("application/pdf")])
        let b: JSONValue = .object(["url": .string("https://example.com/b.jpg"), "type": .string("image/jpeg")])
        original["metadata"]["attachments"] = .array([a, b])
        let part = ChatBubbles.part(original, key: "attachment-0", text: "a.pdf", metadata: .object(["attachments": .array([a])]))
        var updated = try XCTUnwrap(ChatMessageDeletion.removing(part, from: original))
        XCTAssertEqual(updated["metadata"]["attachments"].array, [b])
        XCTAssertEqual(updated["content"], original["content"])
        for _ in 0..<2 { updated = try XCTUnwrap(ChatMessageDeletion.removing(ChatBubbles.textParts(updated)[0], from: updated)) }
        XCTAssertTrue(ChatBubbles.textParts(updated).isEmpty)
        XCTAssertEqual(updated["metadata"]["attachments"].array, [b])
    }
    func testCollectedChildDeletionPreservesOtherChildAndRemapsAttachments() throws {
        let a: JSONValue = .object(["url": .string("https://example.com/a.jpg"), "type": .string("image/jpeg")])
        let b: JSONValue = .object(["url": .string("https://example.com/b.pdf"), "type": .string("application/pdf")])
        var parent = message(); parent["role"] = .string("user")
        parent["metadata"]["attachments"] = .array([a, b])
        parent["metadata"]["batchMessages"] = .array([
            .object(["role": .string("user"), "content": .string("one"), "metadata": .object(["batchAttachmentIndices": .array([.number(0)])])]),
            .object(["role": .string("user"), "content": .string("two"), "metadata": .object(["batchAttachmentIndices": .array([.number(1)])])])])
        let children = ChatBubbles.batchOriginals(parent)
        let updated = try XCTUnwrap(ChatMessageDeletion.removing(children[0], from: parent))
        let kept = try XCTUnwrap(ChatBubbles.batchOriginals(updated).first)
        XCTAssertEqual(kept["content"].string, "two")
        XCTAssertEqual(kept["metadata"]["attachments"].array, [b])
        XCTAssertEqual(updated["metadata"]["attachments"].array, [b])
    }
    @MainActor func testOpeningAndReconnectCatchRepliesWrittenBeforeSocketSubscription() async throws {
        MessageDeletionProtocol.fail = false
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MessageDeletionProtocol.self]
        let http = URLSession(configuration: configuration)
        let api = APIClient(baseURL: "https://delete.fixture", historyURL: "https://delete.fixture", token: UUID().uuidString, requestSession: http)
        var rereads = 0
        let chat = ChatSession(socketFactory: { _ in RecoverySocket() }, heartbeatInterval: 1000)
        let history: JSONValue = .object(["conversation": .object(["id": .string("room"), "codexThreadId": .string("thread")]), "messages": .array([])])
        chat.configureConnection(api: api, endpoint: "wss://delete.fixture", historyReader: { _ in rereads += 1; return history })
        defer { chat.disconnect(); http.invalidateAndCancel() }
        let opened = await chat.open(.object(["id": .string("room")]))
        XCTAssertTrue(opened)
        try await chat.connect()
        XCTAssertEqual(rereads, 1, "Resume must catch replies completed after the initial HTTP read")
        chat.disconnect()
        try await chat.connect()
        XCTAssertEqual(rereads, 2, "A later reconnect must recover replies and deletions made while offline")
    }
    @MainActor func testServerFailureKeepsMessageAndSuccessPersistsExactBubble() async throws {
        MessageDeletionProtocol.fail = true
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MessageDeletionProtocol.self]
        let http = URLSession(configuration: configuration)
        let api = APIClient(baseURL: "https://delete.fixture", historyURL: "https://delete.fixture", token: "fixture", requestSession: http)
        let outbox = ChatSendOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = ChatSession(sendOutbox: outbox)
        chat.configureConnection(api: api, endpoint: "wss://delete.fixture")
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel() }
        let original = message(); chat.messages = [original]
        let part = ChatBubbles.textParts(original)[0]
        await chat.deleteMessagePart(part)
        XCTAssertEqual(chat.messages, [original])
        XCTAssertNotNil(chat.error)
        MessageDeletionProtocol.fail = false
        await chat.deleteMessagePart(part)
        XCTAssertEqual(chat.messages.first?["content"].string, "第二句。")
        await chat.deleteMessagePart(ChatBubbles.textParts(chat.messages[0])[0])
        XCTAssertTrue(chat.messages.isEmpty)
        MessageDeletionProtocol.ackOnly = true
        defer { MessageDeletionProtocol.ackOnly = false }
        chat.messages = [original]
        await chat.deleteMessagePart(part)
        XCTAssertEqual(chat.messages.first?["content"].string, "第二句。", "Mac acknowledgements require a read-back of the edited message")
    }
}

private final class MessageDeletionProtocol: URLProtocol {
    nonisolated(unsafe) static var fail = false
    nonisolated(unsafe) static var ackOnly = false
    nonisolated(unsafe) static var saved: JSONValue = .null
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "delete.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
        }
        let body = (try? JSONDecoder().decode(JSONValue.self, from: bytes)) ?? .null
        var result: JSONValue = Self.fail ? .object(["error": .string("synthetic offline")]) : (request.httpMethod == "DELETE" ? .object(["ok": .bool(true)]) : .object(["message": body]))
        if Self.ackOnly, !Self.fail, request.httpMethod == "POST" { Self.saved = body; result = .object(["ok": .bool(true)]) }
        if request.httpMethod == "GET" {
            result = .object(["conversation": .object(["id": .string(Self.ackOnly ? request.url!.lastPathComponent : "room"), "codexThreadId": .string("thread")]), "messages": .array(Self.ackOnly ? [Self.saved] : [])])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.fail ? 503 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(result)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ActivityCalendarPagingTests: XCTestCase {
    func testWeekCrossesYearBoundaryWithoutDroppingDays() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T04:00:00Z"))
        XCTAssertEqual(JournalDates.weekDays(date).map { JournalDates.label($0) },
                       ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"])
        let previous = try XCTUnwrap(JournalDates.calendar.date(byAdding: .day, value: -7, to: date))
        XCTAssertEqual(JournalDates.label(JournalDates.weekDays(previous)[0]), "2026-12-21")
    }

    func testMonthPagingClampsLeapFebruaryAndSundayBelongsToPriorWeek() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-31T04:00:00Z"))
        XCTAssertEqual(JournalDates.label(JournalDates.moveMonth(date, by: 1)), "2024-02-29")
        let sunday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-18T04:00:00Z"))
        XCTAssertEqual(JournalDates.label(JournalDates.weekDays(sunday)[0]), "2026-10-12")
    }
}

#if !targetEnvironment(macCatalyst)
final class CompanionContentTests: XCTestCase {
    func testExistingActivityDecodesAndKeepsNameDuringAvatarRefresh() throws {
        var state = try JSONDecoder().decode(VesperCompanionAttributes.ContentState.self, from: Data(#"{"avatarRevision":0}"#.utf8))
        XCTAssertEqual(state.displayName, "Rowan")
        XCTAssertNil(state.greeting)
        state.name = "Sol"; state.greeting = "Come as you are."
        state.avatarRevision += 1
        let restored = try JSONDecoder().decode(VesperCompanionAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.displayName, "Sol")
        XCTAssertEqual(restored.greeting, "Come as you are.")
        XCTAssertEqual(restored.avatarRevision, 1)
    }
    func testRotatingGreetingsComeFromChatAndDoNotRepeatImmediately() {
        for line in ChatWelcomeLines.all {
            let next = ChatWelcomeLines.next(after: line)
            XCTAssertNotEqual(next, line)
            XCTAssertTrue(ChatWelcomeLines.all.contains(next))
        }
    }
}
#endif

final class ContactDisplayNameTests: XCTestCase {
    @MainActor func testRenameUpdatesRoleLabelsAndKeepsBackendsIndependent() {
        let first = AppStore(loadState: { _ in .null })
        let second = AppStore(backend: .mac, loadState: { _ in .null })
        first.documents["profile"] = .object(["agentName": .string("  Sol  ")])
        second.documents["profile"] = .object(["agentName": .string("Other")])
        XCTAssertEqual(first.agentDisplayName, "Sol")
        XCTAssertEqual(first.personDisplayName("Rowan"), "Sol")
        XCTAssertEqual(first.personLabel("Rowan 已读"), "Sol 已读")
        first.documents["profile"] = .object(["agentName": .string("哥哥")])
        XCTAssertEqual(first.personDisplayName("Rowan"), "哥哥")
        XCTAssertEqual(second.personDisplayName("Rowan"), "Other")
        XCTAssertEqual(first.personDisplayName("Vera"), "Vera")
        XCTAssertEqual(first.personDisplayName("Book author"), "Book author")
        XCTAssertEqual(JournalAuthor.rowan.rawValue, "Rowan")
    }
    @MainActor func testDefaultInstructionsFollowNameAndCustomInstructionsStayExact() {
        let store = AppStore(loadState: { _ in .null })
        store.documents["profile"] = .object(["agentName": .string("Sol")])
        XCTAssertTrue(store.resolvedAgentInstructions(nil).contains("You are Sol,"))
        XCTAssertTrue(store.resolvedAgentInstructions("You are Rowan, Vera’s familiar companion. Speak naturally in Chinese.").contains("You are Sol,"))
        let custom = "Use Rowan as the character name in this story."
        XCTAssertEqual(store.resolvedAgentInstructions(custom), custom)
        XCTAssertEqual(store.resolvedAgentInstructions(""), "")
    }
    #if !targetEnvironment(macCatalyst)
    func testLegacyCallContentAcceptsNameWithoutLosingControls() throws {
        var state = try JSONDecoder().decode(VesperCallAttributes.ContentState.self, from: Data(#"{"isVideo":true,"muted":true,"speakerEnabled":false}"#.utf8))
        state.name = "Sol"
        let restored = try JSONDecoder().decode(VesperCallAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.displayName, "Sol")
        XCTAssertTrue(restored.isVideo); XCTAssertTrue(restored.muted); XCTAssertFalse(restored.speakerEnabled)
    }
    #endif
}

@MainActor final class ChatImageMemoryTests: XCTestCase {
    private func photo(width: Int, height: Int) throws -> Data {
        try autoreleasepool {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            return try XCTUnwrap(renderer.jpegData(withCompressionQuality: 0.9) { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            })
        }
    }

    func testLargePhotoIsPixelBoundedBeforeUploadAndPreview() async throws {
        let source = try photo(width: 6000, height: 4000)
        let upload = try await ChatImageProcessing.prepare(source)
        let prepared = try XCTUnwrap(UIImage(data: upload)?.cgImage)
        XCTAssertEqual(prepared.width, 2560)
        XCTAssertEqual(Double(prepared.width) / Double(prepared.height), 1.5, accuracy: 0.002)
        XCTAssertLessThanOrEqual(upload.count, ChatImageProcessing.uploadByteLimit)
        let decodedPreview = await ChatImageProcessing.preview(source, maxPixels: 240)
        let preview = try XCTUnwrap(decodedPreview?.cgImage)
        XCTAssertEqual(preview.width, 240)
        XCTAssertLessThanOrEqual(preview.bytesPerRow * preview.height, 240 * 240 * 8)
    }

    func testSmallPhotoIsNotUpscaledAndInvalidDataFailsCleanly() async throws {
        let small = try photo(width: 160, height: 90)
        let prepared = try await ChatImageProcessing.prepare(small)
        XCTAssertEqual(UIImage(data: prepared)?.size, CGSize(width: 160, height: 90))
        XCTAssertNil(ChatImageProcessing.thumbnail(Data("not a photo".utf8), maxPixels: 240))
        do {
            _ = try await ChatImageProcessing.prepare(Data("not a photo".utf8))
            XCTFail("Invalid images must be rejected")
        } catch { XCTAssertTrue(error is ServiceError) }
    }
    func testAvatarBase64DecodesIntoSmallPreview() async throws {
        let data = try photo(width: 2400, height: 1200)
        let prepared = try await ChatImageProcessing.prepareAvatar(data)
        XCTAssertEqual(UIImage(data: prepared)?.cgImage?.width, 640)
        XCTAssertEqual(UIImage(data: prepared)?.cgImage?.height, 320)
        let source = "data:image/jpeg;base64," + data.base64EncodedString()
        let loaded = await ChatAvatarImageCache().image(for: ChatAvatarSource(source: source, baseURL: "https://fixture.test"))
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.cgImage?.width, 160)
        XCTAssertEqual(image.cgImage?.height, 80)
    }
    func testAvatarCacheCoalescesLoadsAndReusesImageUntilSourceChanges() async throws {
        var loads = 0
        let preview = try XCTUnwrap(ChatImageProcessing.thumbnail(try photo(width: 160, height: 160), maxPixels: 160))
        let cache = ChatAvatarImageCache { _ in
            loads += 1
            try? await Task.sleep(for: .milliseconds(20))
            return preview
        }
        let source = ChatAvatarSource(source: "/avatar.jpg", baseURL: "https://fixture.test")
        async let first = cache.image(for: source)
        async let simultaneous = cache.image(for: source)
        let pair = await (first, simultaneous)
        XCTAssertTrue(pair.0 === preview && pair.1 === preview)
        for _ in 0..<40 { let reused = await cache.image(for: source); XCTAssertTrue(reused === preview) }
        XCTAssertEqual(loads, 1, "Reopening and unrelated redraws reuse the decoded image")
        _ = await cache.image(for: ChatAvatarSource(source: "/new-avatar.jpg", baseURL: source.baseURL))
        XCTAssertEqual(loads, 2, "Choosing a new avatar loads the new source")
        _ = await cache.image(for: ChatAvatarSource(source: source.source, baseURL: "https://other.test"))
        XCTAssertEqual(loads, 3, "Relative avatar paths remain scoped to their server")
    }
}

#if !targetEnvironment(macCatalyst)
@MainActor final class CompanionPokeTests: XCTestCase {
    func testMessageOriginIsStoredWithoutChangingVisibleContent() {
        let message = ChatQueuedMessage(text: "hello").message(conversationID: "room")
        XCTAssertEqual(message["content"].string, "hello")
        XCTAssertEqual(ChatDeviceOrigin.label(message), ChatDeviceOrigin.current)
        var old = message
        old["metadata"]["originDevice"] = .null
        XCTAssertNil(ChatDeviceOrigin.label(old))
    }
    func testPokeTapUsesContactNameWithoutChangingOriginalMessageOrReply() throws {
        let tap: JSONValue = .object(["id": .string("poke:fixture:tap"), "role": .string("user"),
            "content": .string("（我在锁屏上轻轻拍了拍你。）"),
            "metadata": .object(["companionPokeId": .string("fixture")])])
        let original = tap
        XCTAssertEqual(ChatPokeNotice.text(tap, agentName: "Ash"), "我拍了拍“Ash”")
        XCTAssertEqual(ChatPokeNotice.text(tap, agentName: "Sol"), "我拍了拍“Sol”")
        var watchTap = tap
        watchTap["metadata"]["source"] = .string("watch")
        XCTAssertEqual(ChatPokeNotice.text(watchTap, agentName: "Ash"), "我拍了拍“Ash” · Apple Watch")
        XCTAssertEqual(tap, original)
        var reply = tap; reply["role"] = .string("agent"); reply["id"] = .string("poke:fixture:reply")
        XCTAssertNil(ChatPokeNotice.text(reply, agentName: "Ash"))
        var ordinary = tap; ordinary["metadata"] = .object([:])
        XCTAssertNil(ChatPokeNotice.text(ordinary, agentName: "Ash"), "Typed words must not be mistaken for a tap")
        var watchText = tap
        watchText["metadata"] = .object(["companionPokeId": .string("fixture"), "watchMessage": .bool(true),
                                          "originDevice": .string("Apple Watch")])
        XCTAssertNil(ChatPokeNotice.text(watchText, agentName: "Ash"), "Watch text must remain ordinary chat")
    }
    func testBackgroundIntentAndLegacyBannerState() throws {
        XCTAssertFalse(PokeVesperCompanionIntent.openAppWhenRun)
        let legacy = try JSONDecoder().decode(VesperCompanionAttributes.ContentState.self, from: Data(#"{"avatarRevision":0,"name":"Sol","greeting":"Hello"}"#.utf8))
        XCTAssertNil(legacy.pokeStatus)
        XCTAssertEqual(legacy.displayName, "Sol")
        var updated = legacy; updated.pokeStatus = "已敲一下"
        let roundTrip = try JSONDecoder().decode(VesperCompanionAttributes.ContentState.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(roundTrip.greeting, "Hello")
        XCTAssertEqual(roundTrip.pokeStatus, "已敲一下")
    }
    func testScreenReplyAndSampledSceneReachOnlyTheirChatContext() {
        let reply: JSONValue = .object(["id": .string("screen:fixture:reply"), "conversationId": .string("screen-room"),
            "role": .string("agent"), "content": .string("fixture viewing comment"), "status": .string("delivered"),
            "metadata": .object(["screenFrameId": .string("fixture"), "screenScene": .string("fixture sampled scene")])])
        let context = ChatTranscript.wakeContext([reply], conversationID: "screen-room", threadID: "interactive-thread")
        XCTAssertTrue(context.contains("fixture viewing comment"))
        XCTAssertTrue(context.contains("fixture sampled scene"))
        XCTAssertTrue(context.contains("quoted history"))
        XCTAssertEqual(ChatTranscript.wakeContext([reply], conversationID: "other-room", threadID: "interactive-thread"), "")
        var pending = reply; pending["status"] = .string("streaming")
        XCTAssertEqual(ChatTranscript.wakeContext([pending], conversationID: "screen-room", threadID: nil), "")
        let deleted = ChatTranscript.merge([reply], incoming: [], tombstones: [.object(["messageId": reply["id"]])])
        XCTAssertEqual(ChatTranscript.wakeContext(deleted, conversationID: "screen-room", threadID: nil), "")
    }
    func testTargetStaysScopedAndPokeReplyReachesConversationContext() throws {
        let token = UUID().uuidString
        let api = APIClient(baseURL: "https://fixture.test", historyURL: "https://fixture.test/history", token: token)
        var other = api; other.token = UUID().uuidString
        let file = try XCTUnwrap(CompanionPokeDelivery.targetURL(api))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        CompanionPokeDelivery.remember(api: api, conversationID: "original-room", model: "fixture-model")
        XCTAssertEqual(CompanionPokeDelivery.target(api)?.conversationID, "original-room")
        XCTAssertNil(CompanionPokeDelivery.target(other))
        let reply: JSONValue = .object(["id": .string("poke:fixture:reply"), "conversationId": .string("original-room"), "role": .string("agent"), "content": .string("fixture response"), "status": .string("delivered"), "createdAt": .string("2026-10-13T06:00:00Z"), "metadata": .object(["companionPokeId": .string("fixture")])])
        XCTAssertTrue(ChatTranscript.wakeContext([reply], conversationID: "original-room", threadID: "thread").contains("fixture response"))
        XCTAssertEqual(ChatTranscript.wakeContext([reply], conversationID: "other-room", threadID: "thread"), "")
    }
}
#endif

@MainActor private final class FixtureChatBackgroundExecution: ChatBackgroundExecution {
    var permitsBackground = false
    var expiration: (@MainActor () -> Void)?
    var finishes: [Bool] = []
    var steps: [Int] = []
    func begin(title: String, expiration: @escaping @MainActor () -> Void) {
        permitsBackground = true; self.expiration = expiration
    }
    func update(step: Int, subtitle: String) { steps.append(step) }
    func finish(success: Bool) { if permitsBackground { finishes.append(success) }; permitsBackground = false; expiration = nil }
    func expire() { let callback = expiration; permitsBackground = false; expiration = nil; callback?() }
}

@MainActor final class ChatBackgroundReplyTests: XCTestCase {
    private func make(_ sockets: [RecoverySocket], lease: FixtureChatBackgroundExecution) -> ChatSession {
        var next = 0
        let chat = ChatSession(socketFactory: {
            _ in let socket = sockets[min(next, sockets.count - 1)]; next += 1; return socket
        }, delay: { seconds in try await Task.sleep(for: .milliseconds(seconds >= 100 ? 100_000 : 5)) }, heartbeatInterval: 1000, backgroundExecution: lease)
        chat.configureConnection(api: APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example", token: "fixture"), endpoint: "wss://invalid.example", threadID: "thread")
        return chat
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testBackgroundGrantCoversPreparationBeforeSocketConnection() async throws {
        let lease = FixtureChatBackgroundExecution(), socket = RecoverySocket()
        let chat = make([socket], lease: lease); defer { chat.disconnect() }
        chat.busy = true; chat.beginBackgroundReply()
        chat.sceneChanged(active: false)
        try await chat.connect()
        XCTAssertEqual(socket.closeCode, .invalid)
        XCTAssertTrue(socket.packets.contains { $0["method"].string == "thread/resume" })
        XCTAssertTrue(lease.permitsBackground)
    }
    func testAcceptedSendReleasesIOSTaskBeforeRemoteReply() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: root)
        defer { outbox.stop(); try? FileManager.default.removeItem(at: root) }
        let lease = FixtureChatBackgroundExecution(), socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000,
                               sendOutbox: outbox, backgroundExecution: lease)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example",
                            token: UUID().uuidString, requestSession: http)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""
        defer { chat.disconnect() }
        let sent = await chat.send("Please do a long task")
        XCTAssertTrue(sent)
        XCTAssertEqual(lease.finishes, [true])
        XCTAssertFalse(lease.permitsBackground)
        XCTAssertTrue(chat.busy, "The remote turn is still running after the local send completes")
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 1)
    }
    func testReplyFinishesInBackgroundWithoutClosingOnHomeGesture() async throws {
        let lease = FixtureChatBackgroundExecution(), socket = RecoverySocket()
        let chat = make([socket], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.busy = true; chat.beginBackgroundReply(); chat.sceneChanged(active: false)
        XCTAssertEqual(socket.closeCode, .invalid)
        try socket.emit(.object(["method": .string("item/started"), "params": .object(["threadId": .string("thread"), "item": .object(["id": .string("background-reply"), "type": .string("agentMessage")])])]))
        try socket.emit(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("background-reply"), "delta": .string("Received while backgrounded")])]))
        await eventually { chat.messages.first?["content"].string == "Received while backgrounded" }
        XCTAssertEqual(socket.closeCode, .invalid)
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object(["turn": .object(["id": .string("turn"), "status": .string("completed")])])]))
        await eventually { !chat.busy }
        XCTAssertEqual(lease.finishes, [true])
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(socket.closeCode, .invalid)
        XCTAssertFalse(socket.packets.contains { $0["method"].string == "turn/start" })
    }
    func testFailedCommandAndErrorNoticeDoNotEndActiveBackgroundTurn() async throws {
        let lease = FixtureChatBackgroundExecution(), socket = RecoverySocket()
        let chat = make([socket], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.busy = true; chat.beginBackgroundReply(); chat.sceneChanged(active: false)
        chat.busy = false
        try socket.emit(.object(["method": .string("turn/started"), "params": .object([
            "threadId": .string("thread"), "turn": .object(["id": .string("turn")])
        ])]))
        await eventually { chat.busy }
        XCTAssertTrue(lease.steps.contains(1), "A turn/start event confirms server handoff even if the RPC receipt is delayed")
        XCTAssertEqual(lease.finishes, [true], "The iOS task ends when the VPS accepts the turn, before its tools finish")
        XCTAssertFalse(lease.permitsBackground)
        try socket.emit(.object(["method": .string("item/completed"), "params": .object([
            "threadId": .string("thread"), "turnId": .string("turn"), "item": .object([
                "id": .string("failed-command"), "type": .string("commandExecution"),
                "status": .string("failed"), "exitCode": .number(1)
            ])
        ])]))
        await eventually { chat.messages.contains { $0.id == "execution-failed-command" } }
        XCTAssertTrue(chat.busy)
        XCTAssertEqual(lease.finishes, [true])
        try socket.emit(.object(["method": .string("error"), "params": .object([
            "turnId": .string("turn"), "error": .object(["message": .string("Command failed; retrying")])
        ])]))
        await eventually { chat.error == "Command failed; retrying" }
        XCTAssertTrue(chat.busy)
        XCTAssertEqual(lease.finishes, [true])
        try socket.emit(.object(["method": .string("item/started"), "params": .object([
            "threadId": .string("thread"), "turnId": .string("turn"),
            "item": .object(["id": .string("next-command"), "type": .string("commandExecution")])
        ])]))
        await eventually { chat.messages.contains { $0.id == "execution-next-command" } }
        XCTAssertEqual(socket.closeCode, .invalid)
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object([
            "threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])
        ])]))
        await eventually { !chat.busy }
        XCTAssertEqual(lease.finishes, [true])
        XCTAssertFalse(chat.busy)
    }
    func testFailedRemoteTurnStillCompletesLocalBackgroundObservation() async throws {
        let lease = FixtureChatBackgroundExecution(), socket = RecoverySocket()
        let chat = make([socket], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.busy = true; chat.beginBackgroundReply(); chat.sceneChanged(active: false)
        chat.busy = false
        try socket.emit(.object(["method": .string("turn/started"), "params": .object([
            "threadId": .string("thread"), "turn": .object(["id": .string("turn")])
        ])]))
        await eventually { chat.busy }
        try socket.emit(.object(["method": .string("turn/completed"), "params": .object([
            "threadId": .string("thread"), "turn": .object([
                "id": .string("turn"), "status": .string("failed"),
                "error": .object(["message": .string("Remote turn failed")])
            ])
        ])]))
        await eventually { !chat.busy }
        XCTAssertEqual(lease.finishes, [true])
        XCTAssertEqual(chat.error, "Remote turn failed")
        XCTAssertFalse(chat.busy)
    }
    func testReturningWhileReplyContinuesKeepsOriginalConnection() async throws {
        let lease = FixtureChatBackgroundExecution(), socket = RecoverySocket()
        let chat = make([socket], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.busy = true; chat.beginBackgroundReply()
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(socket.closeCode, .invalid)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "thread/resume" }.count, 1)
        XCTAssertTrue(lease.permitsBackground)
    }
    func testExpirationRetainsHistoryAndRecoversWithoutResending() async throws {
        let lease = FixtureChatBackgroundExecution(), first = RecoverySocket(), second = RecoverySocket()
        let chat = make([first, second], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.messages = [.object(["id": .string("saved"), "content": .string("Keep")])]
        chat.busy = true; chat.beginBackgroundReply(); chat.sceneChanged(active: false)
        lease.expire()
        XCTAssertEqual(first.closeCode, .goingAway)
        XCTAssertEqual(chat.messages.first?.id, "saved")
        chat.sceneChanged(active: true)
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } }
        XCTAssertFalse((first.packets + second.packets).contains { $0["method"].string == "turn/start" })
    }
    func testNetworkRecoveryContinuesWhileBackgroundGrantIsValid() async throws {
        let lease = FixtureChatBackgroundExecution(), first = RecoverySocket(), second = RecoverySocket()
        let chat = make([first, second], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.busy = true; chat.beginBackgroundReply(); chat.sceneChanged(active: false)
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } }
        XCTAssertTrue(lease.permitsBackground)
        XCTAssertFalse(second.packets.contains { $0["method"].string == "turn/start" })
    }
    func testActiveCallKeepsChatConnectionWhileBackgrounded() async throws {
        let lease = FixtureChatBackgroundExecution(), first = RecoverySocket(), second = RecoverySocket()
        let chat = make([first, second], lease: lease); defer { chat.disconnect() }
        try await chat.connect()
        chat.callActive = true
        chat.sceneChanged(active: false)
        XCTAssertEqual(first.closeCode, .invalid)
        XCTAssertFalse(lease.permitsBackground)
        chat.networkChanged(available: false)
        chat.networkChanged(available: true)
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } }
    }
}

@MainActor final class BackgroundChatRefreshTests: XCTestCase {
    private let api = APIClient(baseURL: "https://invalid.example", historyURL: "https://invalid.example/history", token: "background-fixture")
    private func message(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "role": .string("agent"), "content": .string(text), "status": .string("delivered")])
    }
    func testRefreshBoundsReadsUpdatesCacheAndKeepsUnread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "background-refresh-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = ChatInbox(preferences: defaults)
        ChatRecentCache.save(api: api, id: "main", messages: [message("edited", "old"), message("deleted", "remove")], root: root)
        var paths: [String] = []
        try await BackgroundChatRefresh.run(api: api, preferredRooms: ["main", "main"], inbox: inbox, cacheRoot: root, read: { path in
            paths.append(path)
            if path == "/inbox" {
                return .object(["incoming": .array(["main", "b", "c", "d"].map { .object(["conversationId": .string($0), "messageId": .string("new-" + $0)]) })])
            }
            let room = String(path.split(separator: "/")[1].split(separator: "?")[0])
            return .object(["conversation": .object(["id": .string(room)]), "messages": .array([self.message("edited", "updated"), self.message("new-" + room, "new")]), "tombstones": .array([.object(["messageId": .string("deleted")])])])
        })
        XCTAssertEqual(paths.count, 4)
        XCTAssertFalse(paths.contains { $0.contains("/d?") })
        let cached = try XCTUnwrap(ChatRecentCache.load(api: api, id: "main", root: root))["messages"].array
        XCTAssertEqual(cached.first { $0.id == "edited" }?["content"].string, "updated")
        XCTAssertFalse(cached.contains { $0.id == "deleted" })
        XCTAssertTrue(inbox.hasUpdates, "Fetching must not mark messages read")
        XCTAssertNil(ChatRecentCache.load(api: APIClient(baseURL: api.baseURL, historyURL: api.historyURL, token: "other-account"), id: "main", root: root))
    }
    func testAccountChangeOrCancellationCannotCommitLateResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ChatInbox()
        var current = true
        do {
            try await BackgroundChatRefresh.run(api: api, preferredRooms: ["main"], inbox: inbox, cacheRoot: root, isCurrent: { current }, read: { path in
                if path == "/inbox" { return .object(["incoming": .array([])]) }
                current = false
                return .object(["conversation": .object(["id": .string("main")]), "messages": .array([self.message("late", "late")])])
            })
            XCTFail("Account change should cancel the refresh")
        } catch is CancellationError {}
        XCTAssertNil(ChatRecentCache.load(api: api, id: "main", root: root))
        let task = Task {
            try await BackgroundChatRefresh.run(api: api, preferredRooms: ["main"], inbox: inbox, cacheRoot: root, read: { _ in
                try await Task.sleep(for: .seconds(60))
                return .object(["incoming": .array([])])
            })
        }
        await Task.yield(); task.cancel()
        do { try await task.value; XCTFail("Cancelled refresh must not finish successfully") }
        catch is CancellationError {}
        XCTAssertNil(ChatRecentCache.load(api: api, id: "main", root: root))
    }
    func testDeletedRoomIsRemovedWithoutRecreatingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        ChatRecentCache.save(api: api, id: "deleted-room", messages: [message("old", "old")], root: root)
        var paths: [String] = []
        try await BackgroundChatRefresh.run(api: api, preferredRooms: ["deleted-room", "remaining"], inbox: ChatInbox(), cacheRoot: root, read: { path in
            paths.append(path)
            if path == "/inbox" { return .object(["incoming": .array([])]) }
            if path.contains("deleted-room") { throw ServiceError(message: "Deleted", statusCode: 410, code: "conversation_deleted") }
            return .object(["conversation": .object(["id": .string("remaining")]), "messages": .array([self.message("reply", "saved")])])
        })
        XCTAssertEqual(paths.count, 3)
        XCTAssertNil(ChatRecentCache.load(api: api, id: "deleted-room", root: root))
        XCTAssertNotNil(ChatRecentCache.load(api: api, id: "remaining", root: root))
    }
}

@MainActor final class ChatRenderingRegressionTests: XCTestCase {
    func testUnchangedInboxPollingDoesNotInvalidateChat() {
        let suite = "rendering-inbox-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = ChatInbox(preferences: defaults)
        let covers = [ChatInboxCover(conversationId: "room", messageId: "reply", itemId: nil)]
        var changes = 0
        let observation = inbox.objectWillChange.sink { changes += 1 }
        inbox.update(covers, scope: "fixture")
        let initial = changes
        for _ in 0..<10 { inbox.update(covers, scope: "fixture") }
        XCTAssertEqual(changes, initial)
        XCTAssertTrue(inbox.hasUpdates)
        inbox.markDisplayed(conversation: "room", messageIDs: ["reply"])
        XCTAssertFalse(inbox.hasUpdates)
        let read = changes
        inbox.update(covers, scope: "fixture")
        XCTAssertEqual(changes, read)
        withExtendedLifetime(observation) {}
    }
    func testTypingDoesNotPublishSessionOrComposerOrRebuildTranscript() {
        let chat = ChatSession()
        chat.messages = [.object(["id": .string("saved"), "role": .string("agent"), "content": .string("Existing reply")])]
        let presentation = chat.presentation
        var sessionChanges = 0, composerChanges = 0, textChanges = 0
        let session = chat.objectWillChange.sink { sessionChanges += 1 }
        let composer = chat.composer.objectWillChange.sink { composerChanges += 1 }
        let text = chat.composer.text.objectWillChange.sink { textChanges += 1 }
        for value in ["你", "你好", "你好呀", "你好呀\n我回来啦"] { chat.composer.draft = value }
        XCTAssertEqual(textChanges, 4)
        XCTAssertEqual(sessionChanges, 0)
        XCTAssertEqual(composerChanges, 0)
        XCTAssertTrue(chat.presentation === presentation)
        withExtendedLifetime([session, composer, text]) {}
    }
    func testCachedReplyHeadingsPreserveTurnGroupingAndIgnoreUserAndLetters() {
        let messages: [JSONValue] = [
            .object(["id": .string("u"), "role": .string("user"), "content": .string("hello"), "metadata": .object(["turnId": .string("t1")])]),
            .object(["id": .string("activity"), "role": .string("agent"), "content": .string("working"), "metadata": .object(["turnId": .string("t1"), "phase": .string("commentary")])]),
            .object(["id": .string("reply"), "role": .string("agent"), "content": .string("reply"), "metadata": .object(["turnId": .string("t1"), "threadId": .string("thread"), "phase": .string("final_answer")])]),
            .object(["id": .string("other"), "role": .string("agent"), "content": .string("later"), "metadata": .object(["turnId": .string("t2"), "threadId": .string("thread")])]),
            .object(["id": .string("letter"), "role": .string("system"), "content": .string("letter"), "metadata": .object(["turnId": .string("t2"), "blockType": .string("letterReminder"), "letterId": .string("l")])])
        ]
        let snapshot = ChatPresentationSnapshot(messages)
        XCTAssertEqual(snapshot.liveHeadingID(turnID: "t1"), "reply")
        XCTAssertEqual(snapshot.liveHeadingID(turnID: "t2"), "other")
        XCTAssertNil(snapshot.liveHeadingID(turnID: "missing"))
        XCTAssertNil(snapshot.liveHeadingID(turnID: ""))
    }
}

extension ChatBackendContactTests {
    func testActiveContactUsesSavedNameBeforePreviewCacheLoadsAndAfterRename() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contacts = ChatBackendContacts(cacheRoot: root, disk: LocalDocumentDisk(directory: root))
        let api = APIClient(baseURL: "https://names.fixture", historyURL: "https://names.fixture/history", token: "fixture")
        let profile: JSONValue = .object(["agentName": .string("Ash"), "mainConversationId": .string("main")])
        let first = contacts.activeSnapshot(.vps, api: api, profile: profile, conversations: [])
        XCTAssertEqual(first.agentName, "Ash")
        XCTAssertEqual(first.windows.first?.title, "Ash")
        contacts.capture(.vps, api: api, profile: .object(["agentName": .string("Rowan")]), conversations: [.object(["id": .string("main")])])
        XCTAssertEqual(contacts.activeSnapshot(.vps, api: api, profile: profile, conversations: []).agentName, "Ash")
        let other = APIClient(baseURL: "https://other.fixture", historyURL: "https://other.fixture/history", token: "other")
        XCTAssertTrue(contacts.activeSnapshot(.vps, api: other, profile: .null, conversations: []).conversations.isEmpty)
    }
}

extension ContactDisplayNameTests {
    @MainActor func testVerifiedContactRenamePersistsForHomeAlbumAndColdStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LocalDocumentDisk(directory: root)
        var remote: JSONValue = .object(["agentName": .string("Rowan"), "mainConversationId": .string("keep-room"), "other": .string("keep-field")])
        let store = AppStore(disk: disk, requestDocument: { _, _, method, body in
            if method == "PUT" { remote = body?["value"] ?? .null; return .object(["ok": .bool(true)]) }
            return .object(["value": remote])
        })
        store.baseURL = "https://names.fixture"
        store.token = UUID().uuidString
        let saved = await store.mutate("profile", verifySavedValue: true) { value in
            var profile = value; profile["agentName"] = .string("Ash"); return profile
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(store.agentDisplayName, "Ash")
        XCTAssertEqual(store.personDisplayName("Rowan"), "Ash")
        XCTAssertEqual(store.document("profile")["mainConversationId"].string, "keep-room")
        XCTAssertEqual(store.document("profile")["other"].string, "keep-field")
        let reopened = AppStore(disk: disk)
        reopened.baseURL = store.baseURL; reopened.token = store.token
        XCTAssertEqual(reopened.agentDisplayName, "Ash", "The saved name must be ready before a network refresh")
    }
}


extension ChatConnectionRecoveryTests {
    func testChatPokeSendsStructuredEventWithoutConsumingCollectedDraft() async throws {
        SendPreparationProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SendPreparationProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let socket = RecoverySocket()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: root)
        defer { outbox.stop(); try? FileManager.default.removeItem(at: root) }
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000, sendOutbox: outbox)
        let api = APIClient(baseURL: "https://send-preparation.example", historyURL: "https://send-preparation.example", token: UUID().uuidString, requestSession: http)
        chat.configureConnection(api: api, endpoint: "wss://send-preparation.example", threadID: "thread")
        chat.model = ""; chat.effort = ""; chat.replyMode = .collected
        chat.composer.draft = "Keep my unsent words"
        defer { chat.disconnect() }
        var accepted = 0
        let sent = await chat.sendPoke { accepted += 1 }
        XCTAssertTrue(sent); XCTAssertEqual(accepted, 1)
        XCTAssertEqual(chat.composer.draft, "Keep my unsent words")
        XCTAssertTrue(chat.queuedMessages.isEmpty)
        let record = try XCTUnwrap(chat.messages.first { ChatPokeNotice.target($0) == "agent" })
        XCTAssertEqual(record["metadata"]["poke"]["id"].string, record.id)
        XCTAssertEqual(record["metadata"]["originDevice"].string, ChatDeviceOrigin.current)
        XCTAssertEqual(ChatPokeNotice.text(record, agentName: "Ash"), "我拍了拍“Ash” · " + ChatDeviceOrigin.current)
        XCTAssertEqual(socket.packets.filter { $0["method"].string == "turn/start" }.count, 1)
        XCTAssertTrue(socket.packets.first { $0["method"].string == "turn/start" }?["params"]["input"].array.contains {
            $0["text"].string.contains("poke on her " + ChatDeviceOrigin.current)
        } == true)
        XCTAssertTrue(socket.packets.contains { $0["params"]["dynamicTools"].array.contains { $0["name"].string == "send_native_poke" } })
        try await outbox.flush(api)
        XCTAssertTrue(try outbox.pending(api, conversationID: chat.conversationID).isEmpty)

    }
    func testAgentPokePersistsOnceAnimatesOnlyLiveAndDoesNotMergeReply() async throws {
        BubblePersistenceProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BubblePersistenceProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let socket = RecoverySocket()
        let chat = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 1000)
        chat.configureConnection(api: APIClient(baseURL: "https://bubble-test.example", historyURL: "https://bubble-test.example", token: "synthetic", requestSession: http), endpoint: "wss://bubble-test.example", threadID: "thread")
        defer { chat.disconnect() }
        try await chat.connect()
        func packet(_ id: String, thread: String = "thread") -> JSONValue {
            .object(["id": .string(id), "method": .string("item/tool/call"), "params": .object([
                "name": .string("send_native_poke"), "callId": .string(id), "threadId": .string(thread),
                "turnId": .string("reply-turn"), "arguments": .object([:])])])
        }
        try socket.emit(packet("poke-first"))
        await eventually { socket.packets.contains { $0["id"].string == "poke-first" && $0["result"] != .null } }
        XCTAssertEqual(socket.packets.last { $0["id"].string == "poke-first" }?["result"]["success"], .bool(true))
        let saved = try XCTUnwrap(chat.messages.first { ChatPokeNotice.target($0) == "user" })
        XCTAssertEqual(ChatPokeNotice.text(saved, agentName: "Ash"), "Ash 拍了拍我")
        XCTAssertEqual(chat.agentPokeEventID, saved.id)
        XCTAssertTrue(BubblePersistenceProtocol.records.contains { $0.id == saved.id && $0["metadata"]["poke"] == saved["metadata"]["poke"] })
        try socket.emit(packet("poke-retry"))
        await eventually { socket.packets.contains { $0["id"].string == "poke-retry" && $0["result"] != .null } }
        XCTAssertEqual(chat.messages.filter { ChatPokeNotice.target($0) == "user" }.count, 1)
        XCTAssertEqual(chat.agentPokeEventID, saved.id)
        var reply = saved; reply["id"] = .string("real-reply"); reply["content"] = .string("在呢。"); reply["metadata"]["poke"] = .null
        let rows = ChatPresentation.displayRows([saved, reply])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0.presentedMessage["content"].string }, ["（轻轻拍了拍你。）", "在呢。"])
        XCTAssertEqual(ChatPresentationSnapshot([saved, reply]).liveHeadingID(turnID: "reply-turn"), "real-reply")
        let restored = ChatSession()
        restored.messages = [saved]
        XCTAssertEqual(restored.agentPokeEventID, "", "Reading old history must not replay the avatar animation")
        try socket.emit(packet("wrong-room", thread: "other"))
        await eventually { socket.packets.contains { $0["id"].string == "wrong-room" && $0["result"] != .null } }
        XCTAssertEqual(socket.packets.last { $0["id"].string == "wrong-room" }?["result"]["success"], .bool(false))
    }
}

final class ChatWindowMemoryTests: XCTestCase {
    func testLastWindowSurvivesDefaultsReloadAndStaysScopedAcrossServersAndAccounts() throws {
        let suite = "chat-window-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vps = APIClient(baseURL: "https://vps.fixture", historyURL: "https://vps.fixture/history", token: "first-account")
        var mac = vps; mac.baseURL = "https://mac.fixture"; mac.historyURL = "https://mac.fixture/history"
        var other = vps; other.token = "other-account"
        ChatWindowMemory.remember("project-room", api: vps, defaults: defaults)
        ChatWindowMemory.remember("mac-room", api: mac, defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(ChatWindowMemory.last(api: vps, defaults: reopened), "project-room")
        XCTAssertEqual(ChatWindowMemory.last(api: mac, defaults: reopened), "mac-room")
        XCTAssertNil(ChatWindowMemory.last(api: other, defaults: reopened))
        ChatWindowMemory.forget("another-room", api: vps, defaults: reopened)
        XCTAssertEqual(ChatWindowMemory.last(api: vps, defaults: reopened), "project-room")
        ChatWindowMemory.forget("project-room", api: vps, defaults: reopened)
        XCTAssertNil(ChatWindowMemory.last(api: vps, defaults: reopened))
        XCTAssertEqual(ChatWindowMemory.last(api: mac, defaults: reopened), "mac-room")
    }
}

private final class BarkPresenceProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [JSONValue] = []
    static var records: [JSONValue] { lock.lock(); defer { lock.unlock() }; return storage }
    static func reset() { lock.lock(); storage = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bark-presence.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
        }
        let body = (try? JSONDecoder().decode(JSONValue.self, from: bytes)) ?? .null
        if body != .null { Self.lock.lock(); Self.storage.append(body); Self.lock.unlock() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class BarkPresenceTests: XCTestCase {
    func testLeavingChatReleasesLeaseAndOldViewCannotSilenceNewWindow() async throws {
        BarkPresenceProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BarkPresenceProtocol.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let suite = "bark-presence-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let presence = ChatBarkPresence(defaults: defaults)
        let api = APIClient(baseURL: "https://bark-presence.fixture", historyURL: "https://bark-presence.fixture/history", token: "synthetic", requestSession: http)
        func wait(_ count: Int) async { for _ in 0..<100 { if BarkPresenceProtocol.records.count >= count { return }; try? await Task.sleep(for: .milliseconds(5)) } }
        presence.update(api: api, conversation: "first", visible: true, owner: "old-view")
        await wait(1)
        presence.update(api: api, conversation: "first", visible: false, owner: "old-view")
        await wait(2)
        presence.update(api: api, conversation: "second", visible: true, owner: "new-view")
        await wait(3)
        presence.update(api: api, conversation: "first", visible: false, owner: "old-view")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(BarkPresenceProtocol.records.count, 3)
        presence.update(api: api, conversation: "second", visible: false, owner: "new-view")
        await wait(4)
        let records = BarkPresenceProtocol.records
        XCTAssertEqual(records.map { $0["visible"].bool }, [true, false, true, false])
        XCTAssertEqual(records.map { $0["conversationId"].string }, ["first", "first", "second", "second"])
        XCTAssertEqual(Set(records.map { $0["deviceId"].string }).count, 1)
        XCTAssertEqual(records.map { $0["sequence"].number }, [1, 2, 3, 4])
    }
}

private final class ScreenInboxProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    nonisolated(unsafe) static var failure: URLError.Code?
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = []; failure = nil; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "screen-inbox.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        if request.url?.path.hasPrefix("/conversations/") == true, let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure)); return
        }
        let value: JSONValue = .object(["conversation": .object(["id": .string("screen-room")]),
            "messages": .array([.object(["id": .string("screen:fixture:reply"), "conversationId": .string("screen-room"),
                "role": .string("agent"), "content": .string("Fixture screen comment"), "status": .string("delivered"),
                "metadata": .object(["screenFrameId": .string("fixture")])])]), "tombstones": .array([])])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class ScreenInboxMergeTests: XCTestCase {
    func testNewScreenReplyMergesOnceWithoutOpeningTransportOrChangingDraft() async throws {
        ScreenInboxProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScreenInboxProtocol.self]
        let http = URLSession(configuration: config)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = ChatSendOutbox(directory: root)
        let chat = ChatSession(socketFactory: { _ in XCTFail("Merging must not reopen the socket"); return RecoverySocket() }, sendOutbox: outbox)
        defer { chat.disconnect(); outbox.stop(); http.invalidateAndCancel(); ScreenInboxProtocol.reset(); try? FileManager.default.removeItem(at: root) }
        chat.configureConnection(api: APIClient(baseURL: "https://screen-inbox.fixture", historyURL: "https://screen-inbox.fixture", token: UUID().uuidString, requestSession: http), endpoint: "wss://screen-inbox.fixture")
        chat.newConversation(id: "screen-room")
        chat.composer.draft = "Still typing"
        await chat.receiveScreenReply("screen:fixture:reply")
        XCTAssertEqual(chat.messages.map(\.id), ["screen:fixture:reply"])
        XCTAssertEqual(chat.composer.draft, "Still typing")
        XCTAssertEqual(chat.conversationID, "screen-room")
        XCTAssertFalse(chat.busy)
        await chat.receiveScreenReply("screen:fixture:reply")
        await chat.receiveScreenReply("ordinary-message")
        XCTAssertEqual(ScreenInboxProtocol.captured.count, 1)
        XCTAssertEqual(ScreenInboxProtocol.captured.first?.url?.query, "latest=1&limit=40")
    }
}

@MainActor final class CachedHistoryRecoveryTests: XCTestCase {
    private var historyReads: [URLRequest] {
        ScreenInboxProtocol.captured.filter { $0.url?.path == "/conversations/screen-room" }
    }
    private func fixture() throws -> (ChatSession, APIClient, URLSession) {
        ScreenInboxProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScreenInboxProtocol.self]
        let http = URLSession(configuration: config)
        let api = APIClient(baseURL: "https://screen-inbox.fixture", historyURL: "https://screen-inbox.fixture", token: UUID().uuidString, requestSession: http)
        ChatRecentCache.save(api: api, id: "screen-room", messages: [.object(["id": .string("cached"), "role": .string("agent"), "content": .string("Cached fixture"), "status": .string("delivered")])])
        let chat = ChatSession(socketFactory: { _ in XCTFail("Read-only cache recovery must not start a new model thread"); return RecoverySocket() })
        chat.configureConnection(api: api, endpoint: "wss://screen-inbox.fixture")
        XCTAssertTrue(chat.previewConversation("screen-room"))
        return (chat,api,http)
    }
    private func clean(_ chat: ChatSession, _ api: APIClient, _ http: URLSession) {
        chat.disconnect(); http.invalidateAndCancel(); ScreenInboxProtocol.reset()
        if let dir = ChatRecentCache.directory(api: api) { try? FileManager.default.removeItem(at: dir) }
    }
    func testForegroundValidatesCachedChatAutomaticallyAndPreservesDraft() async throws {
        let (chat,api,http) = try fixture(); defer { clean(chat,api,http) }
        chat.composer.draft = "Keep this draft"
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        for _ in 0..<200 { if !chat.showingCachedHistory { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(chat.showingCachedHistory)
        XCTAssertEqual(chat.conversationID, "screen-room")
        XCTAssertEqual(chat.composer.draft, "Keep this draft")
        XCTAssertEqual(chat.messages.first?.id, "screen:fixture:reply")
        XCTAssertEqual(historyReads.count, 1)
        XCTAssertFalse(chat.issueDetails.contains { $0.id == "cached-history" })
    }
    func testCachedRetryDoesNotCreateSocketBeforeValidatedHistory() async throws {
        let (chat,api,http) = try fixture(); defer { clean(chat,api,http) }
        XCTAssertEqual(chat.issueDetails.first { $0.id == "cached-history" }?.action, .connection)
        chat.retryConnection(); chat.retryConnection()
        for _ in 0..<200 { if !chat.showingCachedHistory { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(chat.showingCachedHistory)
        XCTAssertEqual(historyReads.count, 1)
    }
    func testTLSFailureKeepsCachedMessagesAndDraftUntilExplicitRetrySucceeds() async throws {
        let (chat,api,http) = try fixture(); defer { clean(chat,api,http) }
        chat.composer.draft = "Unsent draft"
        ScreenInboxProtocol.failure = .secureConnectionFailed
        chat.retryConnection()
        for _ in 0..<200 { if chat.error != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(chat.showingCachedHistory)
        XCTAssertEqual(chat.messages.map(\.id), ["cached"])
        XCTAssertEqual(chat.composer.draft, "Unsent draft")
        XCTAssertNotNil(chat.error)
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(historyReads.count, 1)
        ScreenInboxProtocol.failure = nil
        chat.retryConnection()
        for _ in 0..<200 { if !chat.showingCachedHistory { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(chat.showingCachedHistory)
        XCTAssertNil(chat.error)
        XCTAssertEqual(historyReads.count, 2)
        XCTAssertEqual(chat.composer.draft, "Unsent draft")
    }
    func testLeavingBeforeRecoveryStartsCancelsTheRead() async throws {
        let (chat,api,http) = try fixture(); defer { clean(chat,api,http) }
        chat.sceneChanged(active: true)
        chat.sceneChanged(active: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(chat.showingCachedHistory)
        XCTAssertTrue(ScreenInboxProtocol.captured.isEmpty)
    }
}
