import XCTest
import SwiftUI
import UIKit
@testable import Vesper

final class ContractTests: XCTestCase {
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
    var hangMethod: String?
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
        if packet["id"] != .null {
            try emit(.object(["id": packet["id"], "result": method == "thread/resume" ? snapshot : .object([:])]))
        }
    }
    func ping() async throws {
        pingCount += 1; connectionPings += 1
        if connectionPings == 1 {
            if hangHandshake { try await withCheckedThrowingContinuation { suspended.append($0) } }
            if handshakeFailure { throw URLError(.badServerResponse) }
        } else if pingFailure { throw URLError(.networkConnectionLost) }
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

@MainActor final class ChatConnectionRecoveryTests: XCTestCase {
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
    func testForegroundAndNetworkRecoveryPreserveConversationAndMessages() async throws {
        let first = RecoverySocket(), second = RecoverySocket(), third = RecoverySocket()
        let chat = session([first, second, third]); defer { chat.disconnect() }
        let id = chat.conversationID
        chat.composer.draft = "Unsent draft"
        chat.composer.images = [Data([1, 2, 3])]
        chat.messages = [.object(["id": .string("saved"), "content": .string("Keep me")])]
        try await chat.connect()
        chat.sceneChanged(active: false); chat.sceneChanged(active: true)
        await eventually { second.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        await eventually { third.packets.contains { $0["method"].string == "thread/resume" } && !chat.reconnecting }
        XCTAssertEqual(chat.conversationID, id); XCTAssertEqual(chat.messages.first?.id, "saved")
        XCTAssertEqual(chat.composer.draft, "Unsent draft")
        XCTAssertEqual(chat.composer.images, [Data([1, 2, 3])])
        XCTAssertNil(chat.error)
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
        try await chat.connect(); chat.sceneChanged(active: false); chat.sceneChanged(active: true)
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
