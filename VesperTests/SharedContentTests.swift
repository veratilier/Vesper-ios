import XCTest
import SwiftUI
import LinkPresentation
import SafariServices
@testable import Vesper

@MainActor final class SharedContentTests: XCTestCase {
    func testMarkdownAndBareLinksKeepDestinationsAndDeduplicate() {
        let text = "[Expo](https://github.com/expo/expo) https://github.com/expo/expo.\n[https://example.com](https://example.org/path?q=1)"
        XCTAssertEqual(ChatMarkdownText.previewURLs(in: text).map(\.absoluteString),
                       ["https://github.com/expo/expo", "https://example.org/path?q=1"])
    }

    func testCodeAndNonWebLinksDoNotBecomeCards() {
        let text = "`https://example.com/code` [email](mailto:test@example.com) [phone](tel:123) [private](https://user:secret@example.com)"
        XCTAssertTrue(ChatMarkdownText.previewURLs(in: text).isEmpty)
        XCTAssertFalse(ChatWebURL.accepts(URL(string: "file:///tmp/sample.pdf")!))
        XCTAssertTrue(ChatWebURL.accepts(URL(string: "http://example.com")!))
    }

    func testPreviewLimitAndChinesePunctuation() {
        let text = "看看 https://example.com/a。\nhttps://example.com/b https://example.com/c https://example.com/d"
        XCTAssertEqual(ChatMarkdownText.previewURLs(in: text).map(\.absoluteString),
                       ["https://example.com/a", "https://example.com/b", "https://example.com/c"])
    }

    func testFileTypeLabelsKeepExtensionAndHandleMissingNames() {
        XCTAssertEqual(ChatFileCard.typeLabel(name: "book.pdf", mime: "application/pdf"), "PDF")
        XCTAssertEqual(ChatFileCard.typeLabel(name: "notes.MD", mime: "text/plain"), "MD")
        XCTAssertEqual(ChatFileCard.typeLabel(name: "", mime: "application/x-unknown"), "File")
    }

    func testCardLayoutAndPreviewScreenshot() async throws {
        let url = URL(string: "https://github.com/expo/expo")!
        let metadata = LPLinkMetadata(); metadata.originalURL = url; metadata.url = url
        metadata.title = "GitHub · expo/expo: An open-source framework for making universal native apps"
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 560, height: 220)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 560, height: 220))
            ("expo/expo" as NSString).draw(at: CGPoint(x: 32, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.white])
        }
        metadata.imageProvider = NSItemProvider(object: artwork)
        let card = ChatLinkCard(url: url, metadata: metadata)
        let file = ChatFileCard(attachment: .object(["name": .string("共读笔记.pdf"), "type": .string("application/pdf"), "size": .number(131072)]))
        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 24) {
            Text("Shared links & files").font(.title2.bold())
            ChatMarkdownText(content: "一起看看 https://github.com/expo/expo")
            card
            file
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let snapshot = XCTAttachment(image: image); snapshot.name = "Chat link and file cards"; snapshot.lifetime = .keepAlways; add(snapshot)
        let linkView = descendants(host.view).compactMap { $0 as? LPLinkView }.first
        XCTAssertGreaterThan(try XCTUnwrap(linkView).bounds.height, 50)
        XCTAssertLessThanOrEqual(try XCTUnwrap(linkView).bounds.width, window.bounds.width - 40)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
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
