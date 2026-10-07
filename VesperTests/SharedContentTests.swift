import XCTest
import SwiftUI
import SafariServices
@testable import Vesper

@MainActor final class SharedContentTests: XCTestCase {
    func testMusicStatusUsesTheDeviceQueueInsteadOfAnOldServerQueue() {
        let live: JSONValue = .object(["track": .object(["id": .string("apple-1")]), "queueLength": .number(5)])
        let result = ChatMusicContext.liveStatus(live, server: .object(["queueLength": .number(1)]))
        XCTAssertEqual(result["queueLength"], .number(5))
        XCTAssertEqual(result["playback"]["track"]["trackId"].string, "apple-1")
    }
    func testMusicSeekClampsToDurationAndRejectsUnknownOrInvalidTimes() throws {
        XCTAssertEqual(try MusicPlayer.seekPosition(45, duration: 180), 45)
        XCTAssertEqual(try MusicPlayer.seekPosition(500, duration: 180), 180)
        XCTAssertEqual(try MusicPlayer.seekPosition(0, duration: 180), 0)
        for value in [-1, Double.nan, Double.infinity] { XCTAssertThrowsError(try MusicPlayer.seekPosition(value, duration: 180)) }
        for duration in [0, -1, Double.nan, Double.infinity] { XCTAssertThrowsError(try MusicPlayer.seekPosition(45, duration: duration)) }
    }
    func testMusicCommandRejectsMissingOrStalePlaybackInsteadOfClaimingSuccess() async {
        let player = MusicPlayer()
        let result = await player.applyControl(.object(["id": .string("seek-fixture"), "action": .string("seek"), "trackId": .string("missing"), "positionSeconds": .number(30)]))
        XCTAssertEqual(result["applied"], .bool(false))
        XCTAssertFalse(result["error"].string.isEmpty)
        let retried = await player.applyControl(.object(["id": .string("seek-fixture"), "action": .string("seek")]))
        XCTAssertEqual(retried, result)
    }

    func testMarkdownAndBareLinksKeepDestinations() {
        let text = "[Expo](https://github.com/expo/expo) https://github.com/expo/expo.\n[https://example.com](https://example.org/path?q=1)"
        XCTAssertEqual(ChatMarkdownText.render(text).runs.compactMap { $0.link?.absoluteString },
                       ["https://github.com/expo/expo", "https://github.com/expo/expo", "https://example.org/path?q=1"])
    }

    func testCodeURLsStayPlainAndNonWebSchemesKeepTheirDestinations() {
        let text = "`https://example.com/code` [email](mailto:test@example.com) [phone](tel:123)"
        XCTAssertEqual(ChatMarkdownText.render(text).runs.compactMap { $0.link?.absoluteString },
                       ["mailto:test@example.com", "tel:123"])
        XCTAssertFalse(ChatWebURL.accepts(URL(string: "file:///tmp/sample.pdf")!))
        XCTAssertFalse(ChatWebURL.accepts(URL(string: "https://user:secret@example.com")!))
        XCTAssertTrue(ChatWebURL.accepts(URL(string: "http://example.com")!))
    }

    func testBareLinkDestinationsExcludeChineseSentencePunctuation() {
        let text = "看看 https://example.com/a。\nhttps://example.com/b https://example.com/c https://example.com/d"
        XCTAssertEqual(ChatMarkdownText.render(text).runs.compactMap { $0.link?.absoluteString },
                       ["https://example.com/a", "https://example.com/b", "https://example.com/c", "https://example.com/d"])
    }

    func testFileTypeLabelsKeepExtensionAndHandleMissingNames() {
        XCTAssertEqual(ChatFileCard.typeLabel(name: "book.pdf", mime: "application/pdf"), "PDF")
        XCTAssertEqual(ChatFileCard.typeLabel(name: "notes.MD", mime: "text/plain"), "MD")
        XCTAssertEqual(ChatFileCard.typeLabel(name: "", mime: "application/x-unknown"), "File")
    }

    func testWebLinkOpensSheetAndDoneReturnsToSameView() async throws {
        var action: OpenURLAction?
        let host = UIHostingController(rootView: OpenURLProbe { action = $0 }.modifier(ChatInAppLinks()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let open = try XCTUnwrap(action)
        open(URL(string: "https://example.com")!)
        try await Task.sleep(for: .milliseconds(700))
        let presented = try XCTUnwrap(host.presentedViewController)
        func safari(_ controller: UIViewController) -> SFSafariViewController? {
            if let browser = controller as? SFSafariViewController { return browser }
            return controller.children.compactMap(safari).first
        }
        let browser = try XCTUnwrap(safari(presented))
        browser.delegate?.safariViewControllerDidFinish?(browser)
        let deadline = Date().addingTimeInterval(4)
        while host.presentedViewController != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(window.rootViewController === host)
    }
}

private struct OpenURLProbe: View {
    @Environment(\.openURL) private var action
    let read: (OpenURLAction) -> Void
    var body: some View { Text("Chat stays open").onAppear { read(action) } }
}


extension SharedContentTests {
    @MainActor func testApplePlaylistRetainsOriginalTrackIdentityAndOrder() {
        let first: JSONValue = .object(["id": .string("library-first"), "source": .string("appleMusic"), "appleMusicId": .string("libraryID1")])
        let second: JSONValue = .object(["id": .string("library-second"), "source": .string("appleMusic"), "appleMusicId": .string("catalogID2")])
        let third: JSONValue = .object(["id": .string("library-third"), "source": .string("appleMusic"), "appleMusicId": .string("catalogID3")])
        let legacy: JSONValue = .object(["id": .string("old-stream"), "source": .string("netease")])
        XCTAssertEqual(MusicPlayer.playableTracks([first, legacy, second, second, third]), [first, second, third])
    }
    func testAppleCardUsesRealSongMetadata() {
        let raw: JSONValue = .object(["kind": .string("song"), "trackId": .number(123), "trackName": .string("Song"), "artistName": .string("Singer"), "artworkUrl100": .string("https://example.com/cover.jpg"), "trackTimeMillis": .number(180000)])
        let song = ChatMusicShare.appleMetadata(raw)!
        XCTAssertEqual(song["appleMusicId"].string, "123")
        XCTAssertEqual(song["title"].string, "Song")
        XCTAssertEqual(song["artist"].string, "Singer")
        XCTAssertEqual(song["duration"].number, 180)
        XCTAssertEqual(ChatMusicShare.normalized(song)["source"].string, "appleMusic")
        XCTAssertNil(ChatMusicShare.appleMetadata(.object(["kind": .string("collection")])))
    }
}


extension SharedContentTests {
    func testPlaybackStoreIDDoesNotMistakeLibraryOrAlbumIDsForSongs() {
        func track(_ id: String, _ url: String = "") -> JSONValue {
            .object(["appleMusicId": .string(id), "appleMusicURL": .string(url)])
        }
        XCTAssertEqual(MusicPlayer.storeID(track("123")), "123")
        XCTAssertEqual(MusicPlayer.storeID(track("i.library", "https://music.apple.com/cn/album/name/111?i=222")), "222")
        XCTAssertEqual(MusicPlayer.storeID(track("", "https://music.apple.com/tw/song/name/333")), "333")
        XCTAssertNil(MusicPlayer.storeID(track("i.library")))
        XCTAssertNil(MusicPlayer.storeID(track("", "https://music.apple.com/cn/album/name/111")))
        XCTAssertNil(MusicPlayer.storeID(track("", "https://example.com/song/333")))
    }
}

extension SharedContentTests {
    func testMusicPageSearchPreservesPlayableTrackIDsAndRejectsOtherProviders() throws {
        let hit: JSONValue = .object(["trackId": .string("apple-123"), "appleMusicId": .string("123"),
            "source": .string("appleMusic"), "title": .string("Song"), "artist": .string("Artist"), "cover": .string("https://example.com/a.jpg")])
        var response: JSONValue = .object(["ok": .bool(true), "result": .object(["provider": .string("appleMusic"), "matches": .array([hit])])])
        let tracks = try MusicCatalog.searchTracks(response)
        XCTAssertEqual(tracks[0].id, "apple-123")
        XCTAssertEqual(tracks[0]["appleMusicId"], hit["appleMusicId"])
        XCTAssertEqual(tracks[0]["cover"], hit["cover"])
        response["result"]["matches"] = .array([])
        XCTAssertEqual(try MusicCatalog.searchTracks(response), [])
        response["result"]["provider"] = .string("netease")
        XCTAssertThrowsError(try MusicCatalog.searchTracks(response))
        XCTAssertThrowsError(try MusicCatalog.searchTracks(.null))
    }
}


extension SharedContentTests {
    func testOnlyAppleLinksBecomeMusicCards() {
        let text = "https://music.163.com/song?id=123 https://open.spotify.com/track/123 https://music.apple.com/cn/album/a/111?i=222"
        let cards = ChatMusicShare.links(in: text)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0]["appleMusicId"].string, "222")
        XCTAssertTrue(ChatMusicShare.isApple(cards[0]))
        XCTAssertFalse(ChatMusicShare.isApple(.object(["id": .string("netease-1"), "appleMusicId": .string("222")])))
        XCTAssertFalse(ChatMusicShare.isApple(.object(["source": .string("netease"), "title": .string("Song")])))
    }
}

extension SharedContentTests {
    private func playback(_ id: String = "apple-1", playing: Bool = true, position: Double = 10) -> JSONValue {
        .object(["track": .object(["id": .string(id), "title": .string("Test song"), "artist": .string("Test artist"), "album": .string("Album")]),
                 "playing": .bool(playing), "resolving": .bool(false), "positionSeconds": .number(position),
                 "durationSeconds": .number(180), "observedAt": .string("2026-10-02T05:00:00Z")])
    }

    func testOrdinaryMessagesDoNotRepeatPlaybackProgressOrEmptyState() {
        let empty: JSONValue = .object(["track": .null, "playing": .bool(false)])
        XCTAssertEqual(ChatMusicContext.update(ChatMusicContext.snapshot(empty), previous: nil), "")
        let first = ChatMusicContext.snapshot(playback())
        var later = playback(position: 80)
        later["observedAt"] = .string("2026-10-02T05:02:00Z")
        later["durationSeconds"] = .number(181)
        later["track"]["album"] = .string("Resolved album")
        XCTAssertEqual(ChatMusicContext.update(ChatMusicContext.snapshot(later), previous: first), "")
        let update = ChatMusicContext.update(first, previous: nil)
        XCTAssertTrue(update.contains("Test song"))
        XCTAssertFalse(update.contains("positionSeconds"))
        XCTAssertFalse(update.contains("observedAt"))
        XCTAssertFalse(update.contains("album"))
    }

    func testTrackPauseResumeAndClearEachProduceOneUpdate() {
        var previous = ChatMusicContext.snapshot(playback())
        let empty: JSONValue = .object(["track": .null, "playing": .bool(false)])
        for live in [playback("apple-2"), playback("apple-2", playing: false), playback("apple-2"), empty] {
            let current = ChatMusicContext.snapshot(live)
            XCTAssertFalse(ChatMusicContext.update(current, previous: previous).isEmpty)
            XCTAssertEqual(ChatMusicContext.update(current, previous: current), "")
            previous = current
        }
    }

    func testResolvingDoesNotEmitTransientPauseOrConsumeStableUpdate() {
        let previous = ChatMusicContext.snapshot(playback())
        var loading = playback("apple-2", playing: false)
        loading["resolving"] = .bool(true)
        XCTAssertNil(ChatMusicContext.snapshot(loading))
        XCTAssertEqual(ChatMusicContext.update(ChatMusicContext.snapshot(loading), previous: previous), "")
        XCTAssertFalse(ChatMusicContext.update(ChatMusicContext.snapshot(playback("apple-2")), previous: previous).isEmpty)
    }

    func testDeliveredHistoryRestoresBaselineAndFailedOrOtherThreadsDoNotConsumeIt() throws {
        let old = ChatMusicContext.snapshot(playback())!
        let new = ChatMusicContext.snapshot(playback("apple-2"))!
        let saved: JSONValue = .object(["id": .string("first"), "conversationId": .string("room"), "role": .string("user"),
            "status": .string("delivered"), "metadata": .object(["threadId": .string("thread"), "musicPlaybackSnapshot": old])])
        var failed = saved
        failed["id"] = .string("second"); failed["metadata"]["musicPlaybackSnapshot"] = new
        for status in ["error", "pending"] {
            failed["status"] = .string(status)
            XCTAssertEqual(ChatMusicContext.previous(in: [saved, failed], conversationID: "room", threadID: "thread"), old)
        }
        failed["status"] = .string("delivered")
        failed["metadata"]["threadId"] = .string("another-thread")
        XCTAssertEqual(ChatMusicContext.previous(in: [saved, failed], conversationID: "room", threadID: "thread"), old)
        failed["metadata"]["threadId"] = .string("thread"); failed["conversationId"] = .string("other-room")
        XCTAssertEqual(ChatMusicContext.previous(in: [saved, failed], conversationID: "room", threadID: "thread"), old)
        XCTAssertNil(ChatMusicContext.previous(in: [saved], conversationID: "room", threadID: "new-thread"))
        failed["conversationId"] = .string("room")
        let restored = try JSONDecoder().decode([JSONValue].self, from: JSONEncoder().encode([saved, failed]))
        let previous = ChatMusicContext.previous(in: restored, conversationID: "room", threadID: "thread")
        XCTAssertEqual(previous, new)
        XCTAssertEqual(ChatMusicContext.update(new, previous: previous), "")
    }

    func testRequestedLiveStatusUsesFreshPhoneProgressWithoutChangingQueueSummary() {
        let server: JSONValue = .object(["queueLength": .number(5), "libraryLength": .number(148), "playback": .object(["positionSeconds": .number(1)])])
        let result = ChatMusicContext.liveStatus(playback(position: 85), server: server)
        XCTAssertEqual(result["playback"]["positionSeconds"].number, 85)
        XCTAssertEqual(result["playback"]["durationSeconds"].number, 180)
        XCTAssertEqual(result["playback"]["track"]["trackId"].string, "apple-1")
        XCTAssertEqual(result["queueLength"].number, 5)
        XCTAssertEqual(result["libraryLength"].number, 148)
        XCTAssertEqual(result["audioIncluded"], .bool(false))
    }
}

extension SharedContentTests {
    func testAppGridOrderRoundTripsAndKeepsAllDestinations() {
        let moved = VesperGridOrder.move(.movieRoom, to: .desire, in: VesperGridOrder.defaults)
        XCTAssertEqual(moved.first, .movieRoom)
        XCTAssertEqual(VesperGridOrder.restore(VesperGridOrder.encode(moved)), moved)
        XCTAssertEqual(Set(moved), Set(VesperGridOrder.defaults))
        XCTAssertEqual(moved.count, VesperGridOrder.defaults.count)
        XCTAssertTrue(moved.contains(.journal))
        let back = VesperGridOrder.move(.movieRoom, to: .bookmarks, in: moved)
        XCTAssertEqual(back, VesperGridOrder.defaults)
    }
    func testAppGridMigratesMissingNewItemsAndRejectsDuplicateOrNonGridEntries() {
        let saved = "[\"Music\",\"Notes\",\"Music\",\"Unknown\",\"Chat\"]"
        let restored = VesperGridOrder.restore(saved)
        XCTAssertEqual(Array(restored.prefix(2)), [.music, .notes])
        XCTAssertEqual(restored.count, VesperGridOrder.defaults.count)
        XCTAssertEqual(Set(restored), Set(VesperGridOrder.defaults))
        XCTAssertEqual(VesperGridOrder.restore("broken"), VesperGridOrder.defaults)
        XCTAssertEqual(VesperGridOrder.restore(""), VesperGridOrder.defaults)
        let legacySketch = VesperGridOrder.restore("[\"随写\",\"Music\",\"Sketch\"]")
        XCTAssertEqual(Array(legacySketch.prefix(2)), [.jottings, .music])
        XCTAssertEqual(legacySketch.filter { $0 == .jottings }.count, 1)
    }
    func testAppGridInvalidOrSameDestinationDoesNotChangeOrder() {
        let pages = VesperGridOrder.defaults
        XCTAssertEqual(VesperGridOrder.move(.notes, to: .notes, in: pages), pages)
        XCTAssertEqual(VesperGridOrder.move(.home, to: .notes, in: pages), pages)
        XCTAssertEqual(VesperGridOrder.move(.notes, to: .home, in: pages), pages)
    }
}


extension SharedContentTests {
    func testMusicCardPublicCoverAndLookupKeepLibraryIdentity() {
        let library: JSONValue = .object(["id": .string("apple-i.local"), "appleMusicId": .string("i.local"),
            "source": .string("appleMusic"), "cover": .string("musicKit://artwork/library/asset"), "title": .string("Library song")])
        XCTAssertEqual(ChatMusicShare.coverURL(library), "", "Native library artwork must use MusicKit, not AsyncImage")
        let publicTrack: JSONValue = .object(["id": .string("apple-123"), "appleMusicId": .string("123"),
            "cover": .string("http://is1-ssl.mzstatic.com/cover.jpg"), "title": .string("Song"), "duration": .number(180)])
        let merged = ChatMusicShare.mergingMetadata(library, lookup: publicTrack)
        XCTAssertEqual(merged.id, library.id)
        XCTAssertEqual(merged["appleMusicId"], library["appleMusicId"])
        XCTAssertEqual(merged["title"].string, "Song")
        XCTAssertEqual(merged["duration"].number, 180)
        XCTAssertEqual(ChatMusicShare.coverURL(merged), "https://is1-ssl.mzstatic.com/cover.jpg")
        XCTAssertEqual(ChatMusicShare.mergingMetadata(publicTrack, lookup: .object([:]))["cover"], publicTrack["cover"])
        XCTAssertEqual(ChatMusicShare.coverURL(.object(["cover": .string("https://user:secret@example.com/a")])), "")
    }
}


extension SharedContentTests {
    func testStickerCaptionReachesTheModelWithItsImageDescription() {
        let sticker: JSONValue = .object(["assetId": .string("asset"), "name": .string("Smile"), "description": .string("A happy smile")])
        let combined = ChatStickerInput.context(text: "今天好开心😌", sticker: sticker)
        XCTAssertTrue(combined.hasPrefix("今天好开心😌\n"))
        XCTAssertTrue(combined.contains("A happy smile"))
        XCTAssertTrue(combined.contains("assetId: asset"))
        XCTAssertTrue(ChatStickerInput.context(text: "", sticker: sticker).hasPrefix("Shared sticker:"))
    }
}

@MainActor final class BubbleInteractionTests: XCTestCase {
    private func message(_ text: String, role: String = "agent") -> JSONValue {
        .object(["id": .string("original"), "conversationId": .string("room"), "role": .string(role), "content": .string(text),
                 "createdAt": .string("2026-10-07T10:35:00Z"), "status": .string("delivered")])
    }
    func testParagraphsKeepMarkdownAndOriginalHistoryIntact() {
        let prose = "第一句。\n\n第二段，放在一起。\n还有一句。\n\n```swift\nlet a = 1\n\nprint(a)\n```"
        let original = message(prose)
        let parts = ChatBubbles.textParts(original)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1]["content"].string, "第二段，放在一起。\n还有一句。")
        XCTAssertEqual(parts[2]["content"].string, "```swift\nlet a = 1\n\nprint(a)\n```")
        XCTAssertEqual(parts.map(\.id), ["original#text-0", "original#text-1", "original#text-2"])
        XCTAssertTrue(parts.allSatisfy { $0["metadata"]["sourceMessageId"].string == original.id })
        XCTAssertEqual(original["content"].string, prose)
        XCTAssertEqual(ChatBubbles.textParts(message(prose, role: "user")).count, 1)
    }
    func testQuotesValidateOriginalAndSurviveStorage() throws {
        let original = message("这张好安静。\n\n像把今天的风也留住了。")
        let quote = try ChatBubbles.verifiedQuote(original: original, excerpt: "像把今天的风也留住了。", conversationID: "room")
        XCTAssertEqual(quote["messageId"].string, "original")
        XCTAssertEqual(quote["partId"].string, "original#text-1")
        XCTAssertThrowsError(try ChatBubbles.verifiedQuote(original: original, excerpt: "编造的原句。", conversationID: "room"))
        XCTAssertThrowsError(try ChatBubbles.verifiedQuote(original: original, excerpt: "", conversationID: "room"))
        var reply = message("这句我想收藏起来。", role: "user")
        reply["metadata"]["replyTo"] = quote
        let reloaded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(ChatBubbles.textParts(reloaded).first?["metadata"]["replyTo"], quote)
        let draft = ChatComposer(); draft.replyTo = quote
        draft.switchConversation(from: "room", to: "other")
        XCTAssertNil(draft.replyTo)
        draft.switchConversation(from: "other", to: "room")
        XCTAssertEqual(draft.replyTo, quote)
    }
    func testStructuredAssistantBubblesAndAttachmentIsolation() throws {
        let quote = try ChatBubbles.verifiedQuote(original: message("原句"), excerpt: "原句", conversationID: "room")
        var original = message("回复一\n\n回复二")
        original["metadata"]["bubbles"] = .array([.object(["text": .string("回复一"), "replyTo": quote]), .object(["text": .string("回复二")])])
        let parts = ChatBubbles.textParts(original)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["metadata"]["replyTo"], quote)
        XCTAssertEqual(parts[1]["metadata"]["replyTo"], .null)
        let file: JSONValue = .object(["name": .string("计划.pdf"), "type": .string("application/pdf")])
        original["metadata"]["attachments"] = .array([file])
        let attachment = ChatBubbles.part(original, key: "attachment-0", text: "计划.pdf", metadata: .object(["attachments": .array([file])]))
        XCTAssertEqual(attachment["metadata"]["attachments"].array, [file])
        XCTAssertTrue(ChatBubbles.textParts(original)[0]["metadata"]["attachments"].array.isEmpty)
        original["metadata"]["attachmentOnly"] = .bool(true)
        XCTAssertTrue(ChatBubbles.textParts(original).isEmpty)
        XCTAssertNoThrow(try NativeToolCatalog.normalize([ChatSession.bubblesTool]))
    }
    func testFloatingActionsDoNotMoveMessageAndFitSmallScreens() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKeyAndVisible() }
        let store = AppStore(); store.token = ""
        let chat = ChatSession(), player = MusicPlayer()
        for width in [320.0, 393.0] {
            let menu = ChatActionMenu()
            var frame = CGRect.zero, invoked = false
            let original = message("这张好安静。\n\n像把今天的风也留住了。")
            let row = ChatMessageRow(message: original, mediaMessages: [], activities: [], liveEvents: [], isLive: false,
                                     replyIsRunning: false, favorite: false, saving: false, busy: false, highlighted: false,
                                     onFavorite: {}, onRemember: {}, onDelete: {}, onReply: { _ in invoked = true })
            let root = ZStack {
                Background()
                VStack {
                    row.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
                    VoiceMessageBar(attachment: .object(["duration": .number(12), "transcript": .string("刚才海边风有点大，不过夕阳特别好看。")]))
                    ChatFileCard(attachment: .object(["name": .string("周末散步计划.pdf"), "type": .string("application/pdf"), "size": .number(248000)]))
                    Spacer()
                }.padding(20)
            }.overlay { ChatActionOverlay(menu: menu) }
                .environmentObject(menu).environmentObject(store).environmentObject(chat).environmentObject(player)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            let host = UIHostingController(rootView: root); window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(400)); host.view.layoutIfNeeded()
            let before = frame
            XCTAssertGreaterThan(before.height, 100)
            XCTAssertGreaterThanOrEqual(before.minX, 0)
            XCTAssertLessThanOrEqual(before.maxX, width)
            menu.show(id: "original#text-1", frame: CGRect(x: width - 260, y: 210, width: 240, height: 48), actions: [
                .init(title: "复制", icon: "doc.on.doc", run: {}), .init(title: "收藏", icon: "bookmark", run: {}),
                .init(title: "引用", icon: "arrowshape.turn.up.left", run: { invoked = true }), .init(title: "转文字", icon: "text.bubble", run: {})])
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            XCTAssertEqual(frame, before, "The floating menu must not reflow chat messages")
            menu.selection?.actions[2].run(); XCTAssertTrue(invoked)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Bubbles-floating-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}

extension BubbleInteractionTests {
    func testQuotedReplyAndTranscriptLayoutInBothThemes() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bubble-layout-fixture"))
        let previousPalette = UserDefaults.standard.string(forKey: "vesperPalette")
        defer {
            defaults.removePersistentDomain(forName: "bubble-layout-fixture")
            if let previousPalette { UserDefaults.standard.set(previousPalette, forKey: "vesperPalette") }
            else { UserDefaults.standard.removeObject(forKey: "vesperPalette") }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        let store = AppStore(); store.token = ""
        let chat = ChatSession(), menu = ChatActionMenu(), music = MusicPlayer()
        for (width, palette) in [(320.0, "white"), (393.0, "black")] {
            defaults.set(palette, forKey: "vesperPalette")
            UserDefaults.standard.set(palette, forKey: "vesperPalette")
            var first = message("这句我想收藏起来。", role: "user")
            first["id"] = .string("vera")
            first["metadata"]["replyTo"] = try ChatBubbles.verifiedQuote(original: message("像把今天的风也留住了。"), excerpt: "像把今天的风也留住了。", conversationID: "room")
            var second = message("那就替你留着。\n\n以后看到它，就想起今天。")
            second["metadata"]["replyTo"] = try ChatBubbles.verifiedQuote(original: first, excerpt: "这句我想收藏起来。", conversationID: "room")
            var voiceFrame = CGRect.zero, transcriptFrame = CGRect.zero
            let root = ZStack {
                Background()
                VStack(spacing: 12) {
                    ForEach([first, second]) { message in
                        ChatMessageRow(message: message, mediaMessages: [], activities: [], liveEvents: [], isLive: false,
                            replyIsRunning: false, favorite: false, saving: false, busy: false, highlighted: false, onFavorite: {}, onRemember: {}, onDelete: {})
                    }
                    HStack {
                        Spacer(minLength: 42)
                        VStack(alignment: .trailing, spacing: 6) {
                            VoiceMessageBar(attachment: .object(["duration": .number(12)]), alignment: .trailing)
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { voiceFrame = $0 }
                            VoiceTranscriptPanel(text: "刚才海边风有点大，不过夕阳特别好看，想让你也听听海浪的声音。", onCollapse: {})
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { transcriptFrame = $0 }
                        }.frame(maxWidth: 250)
                    }
                    Spacer(minLength: 0)
                }.padding(20)
            }.environmentObject(store).environmentObject(chat).environmentObject(menu).environmentObject(music)
                .defaultAppStorage(defaults).preferredColorScheme(palette == "black" ? .dark : .light).foregroundStyle(VesperTheme.ink)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            window.rootViewController = UIHostingController(rootView: root); window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(400)); window.rootViewController?.view.layoutIfNeeded()
            XCTAssertGreaterThan(voiceFrame.minX, transcriptFrame.minX, "A short voice bar is narrower than its transcript")
            XCTAssertEqual(voiceFrame.height, 44, accuracy: 1, "Compact voice bars retain their touch target")
            XCTAssertEqual(voiceFrame.maxX, transcriptFrame.maxX, accuracy: 1)
            XCTAssertGreaterThan(transcriptFrame.height, 90)
            XCTAssertEqual(transcriptFrame.minY - voiceFrame.maxY, 6, accuracy: 1)
            XCTAssertLessThanOrEqual(transcriptFrame.maxX, width - 19)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Quotes-transcript-\(palette)-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
