import XCTest
import SwiftUI
@testable import Vesper

@MainActor final class ChatTerminalSharingTests: XCTestCase {
    func testHistoryPagesKeepEarlierMessagesAndRemoveDuplicates() {
        func message(_ id: String, _ at: String) -> JSONValue { .object(["id":.string(id),"role":.string("user"),"content":.string(id),"createdAt":.string(at)]) }
        let first = message("old","2026-09-29T00:00:00Z"), last = message("new","2026-09-30T00:00:00Z")
        XCTAssertEqual(ChatTerminalHistory.merge([last],[first,last]).map(\.id),["old","new"])
        let path = ChatTerminalHistory.path("rowan",before:"a+b/=中文")
        let url = URLComponents(string:"https://example.com" + path)
        XCTAssertEqual(url?.queryItems?.first { $0.name == "before" }?.value,"a+b/=中文")
        XCTAssertTrue(path.hasPrefix("/conversations/rowan?"))
    }
    func testTerminalWrapsAndKeepsReaderPositionWithoutHorizontalOverflow() async throws {
        let renderer = TerminalTextViewport(text:String(repeating:"wide terminal 测试行 \n",count:150))
        let host = UIHostingController(rootView:renderer)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        host.view.frame = CGRect(x:0,y:0,width:260,height:300); host.view.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.compactMap(find).first }
        let view = try XCTUnwrap(find(host.view))
        view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(view.contentSize.width,view.bounds.width + 1)
        XCTAssertFalse(view.alwaysBounceHorizontal)
        XCTAssertTrue(view.textContainer.widthTracksTextView)
        XCTAssertGreaterThan(view.contentSize.height,view.bounds.height)
        XCTAssertEqual(TerminalTextViewport.columns(for:10),24)
        XCTAssertEqual(TerminalTextViewport.columns(for:2000),120)
        view.setContentOffset(CGPoint(x:0,y:150),animated:false)
        host.rootView = TerminalTextViewport(text:renderer.text + "New output\n")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.contentOffset.x,0)
        XCTAssertEqual(view.contentOffset.y,150,accuracy:1)
    }

    func testPictureBookmarkLayoutRendersLongTextInNarrowWidth() async throws {
        let card: JSONValue = .object(["id":.string("fixture"),"text":.string("留一句读到这里时的心情。\n" + String(repeating:"这是一段用于检查长文字排版的虚构文字。",count:20)),"source":.string("共读室 · 测试书目"),"author":.string("Rowan")])
        let host = UIHostingController(rootView:BookmarkCard(card:card).frame(width:300,height:580).padding(20).background(Color.gray.opacity(0.1)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene); window.rootViewController=host; window.makeKeyAndVisible()
        defer { window.isHidden=true;previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment=XCTAttachment(image:image);attachment.name="Bookmark long text layout";attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertGreaterThan(image.size.width,300)
    }
    func testMusicLinksAreRecognizedWithoutGenericPreviewCards() {
        let text = "https://example.com/a https://evil.music.apple.com/a https://music.apple.com/us/album/test/12?i=987 https://open.spotify.com/track/abc"
        let cards = ChatMusicShare.links(in:text)
        XCTAssertEqual(cards.count,2)
        XCTAssertEqual(cards[0]["appleMusicId"].string,"987")
        XCTAssertEqual(cards[0]["source"].string,"appleMusic")
        XCTAssertEqual(cards[1]["provider"].string,"Spotify")
        XCTAssertEqual(ChatMusicShare.normalized(.object(["trackId":.string("apple-987")])).id,"apple-987")
        XCTAssertTrue(ChatMusicShare.links(in:"https://example.com").isEmpty)
    }
}
