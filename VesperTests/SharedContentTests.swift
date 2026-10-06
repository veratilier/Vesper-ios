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
