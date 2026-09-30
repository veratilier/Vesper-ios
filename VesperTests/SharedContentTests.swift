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
