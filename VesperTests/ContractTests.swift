import XCTest
import Combine
import SwiftUI
import UIKit
@testable import Vesper

private final class StickerAssetProtocol: URLProtocol {
    static var requestedURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestedURL = request.url
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
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
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    static func reset() { lock.lock(); reads = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "history-pagination.example"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.reads += 1; Self.lock.unlock()
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
        let viewer = AlbumPhotoViewer(photos: photos, initialID: photos[4].id, membership: { _, _, _ in }).environmentObject(AppStore())
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
        XCTAssertTrue(chat.hasOlderMessages)
        XCTAssertNil(chat.jumpMessageID)

        await chat.loadOlder()
        XCTAssertEqual(ChatHistoryPaginationProtocol.requestCount, 2)
        XCTAssertEqual(chat.messages.map(\.id), ["older", "latest"])
        XCTAssertFalse(chat.hasOlderMessages)
        XCTAssertNil(chat.jumpMessageID)
        chat.disconnect()
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
        XCTAssertTrue(input.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertNotNil(Data(base64Encoded: String(input.dropFirst("data:image/jpeg;base64,".count))))
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
        if packet["id"] != .null && !method.isEmpty {
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
        XCTAssertEqual(second.packets.first { $0["method"].string == "thread/resume" }?["params"]["threadId"].string, "thread")
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
        if request.httpMethod == "POST", let record = try? JSONDecoder().decode(JSONValue.self, from: bytes) {
            Self.lock.lock(); Self.storage.append(record); Self.lock.unlock()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
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
