import XCTest
import SwiftUI
import UIKit
@testable import Vesper

final class ContractTests: XCTestCase {
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
