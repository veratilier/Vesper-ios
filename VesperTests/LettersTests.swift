import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import Vesper

private final class LettersRefreshProtocol: URLProtocol {
    static var listStarted: XCTestExpectation?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "letters-refresh.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let keeping = request.httpMethod == "PATCH"
        let letter: [String: Any] = ["id": "refresh", "title": "Evening", "author": "Rowan", "recipient": "Vera",
            "createdAt": "2026-10-06T00:00:00Z", "text": "A thought.", "kept": keeping,
            "marks": ["Vera": ["read": false, "kept": keeping], "Rowan": ["read": false, "kept": false]]]
        let body = try! JSONSerialization.data(withJSONObject: keeping ? ["letter": letter] : ["letters": [letter]])
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body); self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (keeping ? 0 : 1), execute: work)
        if !keeping { Self.listStarted?.fulfill() }
    }
    override func stopLoading() { work?.cancel() }
}

private final class LettersLayoutProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("letters-layout.example") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = request.url?.host?.hasPrefix("single") == true ? 1 : 5
        var letters: [[String: Any]] = (0..<count).map { slot in
            ["id": "layout-\(slot)", "title": slot == 0 ? "A little thought for you" : "A small discovery", "author": "Rowan", "recipient": "Vera",
             "createdAt": "2026-10-0\(max(1, 5 - slot))T06:00:00Z", "text": "A little thought."]
        }
        if count > 1 {
            letters.append(["id": "birthday", "title": "For your birthday", "author": "Vera", "recipient": "Rowan", "createdAt": "2026-10-05T06:00:00Z",
                            "unlockAt": "2099-10-29T09:00:00Z", "locked": true])
        }
        letters[0]["author"] = "Vera"; letters[0]["recipient"] = "Rowan"
        letters[0]["marks"] = ["Vera": ["read": true, "kept": false], "Rowan": ["read": true, "kept": true]]
        let body = try! JSONSerialization.data(withJSONObject: ["letters": letters, "serverTime": "2026-10-05T06:00:00Z"])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct ChatBadgeFixture: View {
    @ObservedObject var inbox: ChatInbox
    var selected: Bool
    var body: some View {
        TabView(selection: .constant(0)) {
            ChatView(restoreLatest: false, native: true, inbox: inbox)
                .environment(\.vesperChatTabSelected, selected)
                .environment(\.scenePhase, .active)
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
            Text("Chat").tabItem { Label("Chat", systemImage: "bubble.left") }
                .badge(inbox.hasUpdates ? " " : nil as String?).tag(1)
        }
    }
}

@MainActor final class LettersTests: XCTestCase {
    func testMailboxesUseOnlyTheirRecipientsReadingAndKeepMarks() throws {
        let data = Data(#"{"id":"sent","title":"Evening","author":"Vera","recipient":"Rowan","createdAt":"now","kept":true,"marks":{"Vera":{"read":true,"kept":true},"Rowan":{"read":false,"kept":false}}}"#.utf8)
        var letter = try JSONDecoder().decode(VesperLetter.self, from: data)
        XCTAssertTrue(letter.matchesMailbox("Rowan", filter: "All"))
        XCTAssertTrue(letter.matchesMailbox("Rowan", filter: "Unread"))
        XCTAssertFalse(letter.matchesMailbox("Rowan", filter: "Kept"), "Vera’s bookmark cannot put a letter in Rowan’s Kept")
        XCTAssertFalse(letter.matchesMailbox("Vera", filter: "All"))
        letter.marks?["Rowan"]?.kept = true; letter.marks?["Rowan"]?.read = true
        XCTAssertTrue(letter.matchesMailbox("Rowan", filter: "Kept")); XCTAssertFalse(letter.matchesMailbox("Rowan", filter: "Unread"))
        let incoming = VesperLetter(id: "incoming", title: "", author: "Rowan", createdAt: "now", read: false, kept: true)
        XCTAssertTrue(incoming.matchesMailbox("Vera", filter: "Unread")); XCTAssertTrue(incoming.matchesMailbox("Vera", filter: "Kept"))
        XCTAssertFalse(incoming.matchesMailbox("Rowan", filter: "All"))
    }
    func testOlderArchiveRefreshCannotUndoSuccessfulKeep() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LettersRefreshProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); LettersRefreshProtocol.listStarted = nil }
        var api = APIClient(baseURL: "https://letters-refresh.example", historyURL: "", token: "fixture")
        api.requestSession = session
        let model = LettersStore(); model.configure(api)
        let letter = VesperLetter(id: "refresh", title: "Evening", author: "Rowan", createdAt: "2026-10-06T00:00:00Z", kept: false)
        model.letters = [letter]
        let started = expectation(description: "Archive request takes its older snapshot")
        LettersRefreshProtocol.listStarted = started
        let refresh = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        let kept = await model.keep(letter)
        XCTAssertEqual(kept?.kept, true)
        await refresh.value
        XCTAssertEqual(model.letters.first?.kept, true, "A delayed archive response must not overwrite a newer keep result")
        XCTAssertEqual(model.letters.first?.keepLabels, ["你已收藏"])
    }

    func testLetterReceiptsShowRecipientReadingAndBothKeepersWithoutChangingPersonalMarks() throws {
        let data = Data(#"{"id":"sent","title":"Evening","author":"Vera","recipient":"Rowan","createdAt":"2026-10-06T00:00:00Z","read":true,"kept":false,"marks":{"Vera":{"read":true,"kept":false},"Rowan":{"read":false,"kept":true}}}"#.utf8)
        var letter = try JSONDecoder().decode(VesperLetter.self, from: data)
        XCTAssertEqual(letter.readLabel, "Rowan 未读", "Opening your own copy cannot claim Rowan read it")
        XCTAssertTrue(letter.matchesFilter("Unread")); XCTAssertTrue(letter.matchesFilter("Kept"))
        XCTAssertEqual(letter.keepLabels, ["Rowan 已收藏"]); XCTAssertEqual(letter.kept, false)
        letter.marks?["Rowan"]?.read = true
        XCTAssertEqual(letter.readLabel, "Rowan 已读"); XCTAssertFalse(letter.matchesFilter("Unread"))
        letter.marks?["Vera"]?.kept = true
        XCTAssertEqual(letter.keepLabels, ["你已收藏", "Rowan 已收藏"])
        let old = VesperLetter(id: "old", title: "", author: "Vera", createdAt: "now", read: true)
        XCTAssertNil(old.readerRead, "Missing receipts must stay unknown on older servers")
        let incoming = VesperLetter(id: "incoming", title: "", author: "Rowan", createdAt: "now", read: false)
        XCTAssertEqual(incoming.readLabel, "你未读"); XCTAssertTrue(incoming.matchesFilter("Unread"))
    }
    func testLettersArchiveWithSingleAndFullStacksOnAllPalettes() async throws {
        URLProtocol.registerClass(LettersLayoutProtocol.self)
        defer { URLProtocol.unregisterClass(LettersLayoutProtocol.self) }
        let suite = "letters-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (count, palette) in [(1, "white"), (5, "white"), (5, "blue"), (5, "black")] {
            preferences.set(palette, forKey: "vesperPalette")
            let store = AppStore(); store.baseURL = "https://\(count == 1 ? "single" : "stack").letters-layout.example"; store.token = UUID().uuidString
            let model = LettersStore(); model.configure(store.api); await model.load()
            XCTAssertEqual(model.letters.count, count == 1 ? 1 : count + 1, "The fixture must cover empty and populated Upcoming areas")
            model.saveDraft(showStatus: false)
            XCTAssertEqual(model.status, "", "Restoring or automatically saving a draft must not add a status row to the archive")
            let host = UIHostingController(rootView: TabView(selection: .constant(3)) {
                Text("Home").tabItem { Label("Home", systemImage: "house") }.tag(0)
                Text("Chat").tabItem { Label("Chat", systemImage: "bubble.left") }.badge(" ").tag(1)
                Text("Collection").tabItem { Label("Collection", systemImage: "square.grid.2x2") }.tag(2)
                NavigationStack { ZStack { Background(); LettersView(initialSelection: "layout-0") } }
                    .tabItem { Label("Letters", systemImage: "envelope") }.badge(" ").tag(3)
                Text("Setting").tabItem { Label("Setting", systemImage: "gearshape") }.tag(4)
            }
                .environmentObject(store).defaultAppStorage(preferences).preferredColorScheme(palette == "black" ? .dark : .light))
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 844)
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Letters-archive-\(count)-\(palette)"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testLetterStackStaysWithinPhoneMarginsWhenBrowsingAndSelecting() throws {
        for width in [320, 393, 430] {
            for count in [1, 5] {
                let letters = (0..<count).map { VesperLetter(id: "layout-\($0)", title: "我们的第\($0 + 1)封信", author: "Vera", createdAt: "2026-10-05T06:00:00Z") }
                for selected in [false, true] {
                    let content = LetterStack(letters: letters, hoverID: .constant(nil), selectedID: .constant(selected ? letters.last?.id : nil), colors: LetterColors(palette: .white))
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
                    XCTAssertLessThan(marked.map { $0 / width }.max() ?? 420, 392, "The envelopes must stay above the instructions below them")
                }
            }
        }
    }
    func testChatBadgeClearsOnlyDisplayedIncomingMessagesAndKeepsOtherChatsUnread() throws {
        let suite = "chat-badge-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let inbox = ChatInbox(preferences: preferences)
        let one = ChatInboxCover(conversationId: "one", messageId: "reply-one", itemId: nil)
        let two = ChatInboxCover(conversationId: "two", messageId: "reply-two", itemId: "item-two")
        inbox.update([one,two], scope: "a"); XCTAssertTrue(inbox.hasUpdates)
        inbox.markDisplayed(conversation: "one", messageIDs: ["own-message"]); XCTAssertTrue(inbox.hasUpdates)
        inbox.markDisplayed(conversation: "one", messageIDs: [one.messageId]); XCTAssertTrue(inbox.hasUpdates, "Other chats remain unread")
        inbox.markDisplayed(conversation: "two", messageIDs: ["item-two"]); XCTAssertFalse(inbox.hasUpdates)
        let restored = ChatInbox(preferences: preferences);restored.update([one,two],scope:"a");XCTAssertFalse(restored.hasUpdates)
        restored.update([one,two],scope:"b");XCTAssertTrue(restored.hasUpdates, "Read marks cannot leak between accounts")
        restored.clear();XCTAssertFalse(restored.hasUpdates)
    }
    func testChatBadgeKeepsLoadedButOffscreenRepliesUnread() throws {
        let suite = "chat-visible-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let inbox = ChatInbox(preferences: preferences)
        let cover = ChatInboxCover(conversationId: "one", messageId: "wake:next:final", itemId: nil)
        inbox.update([cover], scope: "a")
        let viewport = CGRect(x: 20, y: 140, width: 350, height: 450)
        for frame in [CGRect(x: 20, y: 610, width: 350, height: 80),
                      CGRect(x: 20, y: 90, width: 350, height: 40),
                      CGRect(x: 20, y: 580, width: 350, height: 80)] {
            let displayed = ChatReadVisibility.displayedIDs(frames: [cover.messageId: frame], viewport: viewport)
            inbox.markDisplayed(conversation: "one", messageIDs: displayed)
            XCTAssertTrue(inbox.hasUpdates, "A loaded reply beyond the viewport or under the composer stays unread")
        }
        inbox.markDisplayed(conversation: "one", messageIDs: ChatReadVisibility.displayedIDs(
            frames: [cover.messageId: CGRect(x: 20, y: 450, width: 350, height: 80)], viewport: viewport))
        XCTAssertFalse(inbox.hasUpdates)
    }
    func testMountedInactiveChatKeepsWakeBadgeUntilVisibleAndRendersRedDot() async throws {
        let suite = "chat-tab-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let inbox = ChatInbox(preferences: preferences)
        let chat = ChatSession(); let store = AppStore(); store.token = ""
        let reply: JSONValue = .object(["id": .string("wake:fixture:final"), "role": .string("agent"), "status": .string("delivered"),
            "content": .string("A new thought for you."), "metadata": .object(["source": .string("automation")])])
        chat.messages = [reply]
        let cover = ChatInboxCover(conversationId: chat.conversationID, messageId: reply.id, itemId: nil)
        inbox.update([cover], scope: "fixture")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let content = { (selected: Bool) in
            ChatBadgeFixture(inbox: inbox, selected: selected).environmentObject(store).environmentObject(chat)
                .environmentObject(chat.composer).foregroundStyle(VesperTheme.ink)
        }
        let host = UIHostingController(rootView: content(false))
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; chat.disconnect() }
        try await Task.sleep(for: .milliseconds(600)); host.view.layoutIfNeeded()
        XCTAssertTrue(inbox.hasUpdates, "A retained Chat view must not clear incoming messages while another tab is selected")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Chat-unread-red-dot"; attachment.lifetime = .keepAlways; add(attachment)
        var pixels = [UInt8](repeating: 0, count: 393 * 844 * 4)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 393, height: 844, bitsPerComponent: 8,
                bytesPerRow: 393 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: window.bounds)
        }
        let redPixels = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 180 && pixels[$0 + 1] < 130 && pixels[$0 + 2] < 130 }
        XCTAssertGreaterThan(redPixels.count, 10, "The native tab bar must actually render a visible red badge")
        host.rootView = content(true)
        for _ in 0..<30 {
            if !inbox.hasUpdates { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(inbox.hasUpdates, "Viewing the visible message clears its unread dot")
        host.rootView = content(false)
        try await Task.sleep(for: .milliseconds(100))
        var next = reply; next["id"] = .string("wake:second:final")
        chat.messages.append(next)
        inbox.update([ChatInboxCover(conversationId: chat.conversationID, messageId: next.id, itemId: nil)], scope: "fixture")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(inbox.hasUpdates, "New wake messages stay unread while the mounted Chat is inactive")
    }
    func testLetterBadgeDistinguishesArrivalUnlockAndReading() throws {
        let suite = "letter-badge-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let inbox = LetterInbox(preferences: preferences), now = Date()
        let future = LetterInboxCover(id: "future", unlockAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(120)))
        inbox.update([future], scope: "a", serverTime: now)
        XCTAssertTrue(inbox.hasUpdates, "A new sealed arrival lights the dot")
        inbox.markArrivalSeen([future.id]); XCTAssertFalse(inbox.hasUpdates, "Seeing a future cover clears the arrival dot")
        inbox.tick(now: now.addingTimeInterval(121)); XCTAssertTrue(inbox.hasUpdates, "Unlocking a seen sealed cover lights the dot again")
        inbox.markRead(future.id); XCTAssertFalse(inbox.hasUpdates, "Reading clears the ready letter")
        let ready = LetterInboxCover(id: "ready", unlockAt: nil)
        inbox.update([ready], scope: "a", serverTime: now); inbox.markArrivalSeen([ready.id])
        XCTAssertTrue(inbox.hasUpdates, "Visiting the list does not mark an available letter as read")
        inbox.markRead(ready.id); XCTAssertFalse(inbox.hasUpdates)
        inbox.update([future], scope: "b", serverTime: now); XCTAssertTrue(inbox.hasUpdates, "Seen arrivals are scoped to the connected account")
        inbox.clear(); XCTAssertFalse(inbox.hasUpdates)
    }
    func testLetterNotificationUsesServerTimeAndOnlyCoverData() throws {
        let server = Date(timeIntervalSince1970: 1800000000)
        let cover = LetterReminderCover(id: "scheduled", title: "For tomorrow", author: "Rowan", unlockAt: ISO8601DateFormatter().string(from: server.addingTimeInterval(91)), due: false)
        let request = try XCTUnwrap(LetterNotifications.request(cover, scope: "account", serverTime: server))
        XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 91)
        XCTAssertEqual(request.content.userInfo["letterId"] as? String, cover.id)
        XCTAssertEqual(request.identifier, "letter-account-scheduled")
        let late = LetterReminderCover(id: "late", title: "", author: "Rowan", unlockAt: ISO8601DateFormatter().string(from: server.addingTimeInterval(-5)), due: true)
        XCTAssertEqual((LetterNotifications.request(late, scope: "account", serverTime: server)?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 1)
        let a = APIClient(baseURL: "https://letters.example", historyURL: "", token: "account-a")
        let b = APIClient(baseURL: "https://letters.example", historyURL: "", token: "account-b")
        XCTAssertNotEqual(LetterNotifications.scope(a), LetterNotifications.scope(b))
    }
    func testLetterRemindersStayVisibleAndDoNotBecomeThinkingOrReplyAnchors() {
        let reminder: JSONValue = .object(["id":.string("letter-one"),"role":.string("system"),"content":.string("可以拆信了"),"metadata":.object(["blockType":.string("letterReminder"),"letterId":.string("one")])])
        XCTAssertFalse(ChatPresentation.isActivity(reminder))
        XCTAssertEqual(ChatPresentation.displayRows([reminder]).count, 1)
        XCTAssertNil(ChatPresentationSnapshot([reminder]).lastReplyID)
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
