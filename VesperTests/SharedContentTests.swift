import XCTest
import SwiftUI
import SafariServices
@testable import Vesper

@MainActor final class SharedContentTests: XCTestCase {
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
