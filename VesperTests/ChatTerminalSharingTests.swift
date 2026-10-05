import XCTest
import SwiftUI
@testable import Vesper

@MainActor final class ChatTerminalSharingTests: XCTestCase {
    func testRecordedTerminalHistoryIncludesCommandsAndOutputsWithoutDuplicatingItems() {
        let old: JSONValue = .object(["id": .string("command"), "type": .string("CommandExecution"), "title": .string("echo synthetic"), "output": .string("synthetic result"), "createdAt": .string("2026-10-01T00:00:00Z")])
        let new: JSONValue = .object(["id": .string("tool"), "type": .string("DynamicToolCall"), "title": .string("test_tool"), "status": .string("completed"), "createdAt": .string("2026-10-01T00:01:00Z")])
        let merged = TerminalRecordedHistory.merge([new], [old, new])
        XCTAssertEqual(merged.map(\.id), ["command", "tool"])
        let text = TerminalRecordedHistory.text(merged, live: "LIVE_SCREEN")
        XCTAssertTrue(text.contains("$ echo synthetic\nsynthetic result"))
        XCTAssertTrue(text.contains("Called test_tool · completed"))
        XCTAssertTrue(text.hasSuffix("LIVE_SCREEN"))
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
    func testLiveTerminalAndReconnectLabelsAcrossPalettes() async throws {
        let original = UserDefaults.standard.string(forKey: "vesperPalette")
        defer {
            if let original { UserDefaults.standard.set(original, forKey: "vesperPalette") }
            else { UserDefaults.standard.removeObject(forKey: "vesperPalette") }
        }
        for palette in ["white", "blue", "black"] {
            UserDefaults.standard.set(palette, forKey: "vesperPalette")
            let history = TerminalTextViewport(text: "Recorded Codex activity\n$ echo synthetic\nsynthetic result\n\n—— Live terminal ——\n> Ready")
                .padding(16).background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .preferredColorScheme(.dark).foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            let image = try await renderFixture(AnyView(history), name: "Live terminal " + palette)
            XCTAssertGreaterThan(brightPixels(image, area: CGRect(x: 16, y: 70, width: 350, height: 280)), 250)
            let connection = ChatConnectionSheet(message: "Chat recovery failed. Tap Retry to start another attempt.", needsRetry: true, retry: {}, close: {})
                .foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            _ = try await renderFixture(AnyView(connection), name: "Connection retry " + palette)
        }
    }

    func testPermissionLayoutsAcrossThemes() async throws {
        let original = UserDefaults.standard.string(forKey: "vesperPalette")
        defer {
            if let original { UserDefaults.standard.set(original, forKey: "vesperPalette") }
            else { UserDefaults.standard.removeObject(forKey: "vesperPalette") }
        }
        for palette in ["white", "black"] {
            UserDefaults.standard.set(palette, forKey: "vesperPalette")
            let scheme: ColorScheme = palette == "black" ? .dark : .light
            _ = try await renderFixture(AnyView(NavigationStack { DevicePermissionsView() }.environment(\.scenePhase, .active).preferredColorScheme(scheme)), name: "Permissions " + palette)
            _ = try await renderFixture(AnyView(NavigationStack { SystemPlannerView(reminderOnly: false) }.preferredColorScheme(scheme)), name: "Calendar permission " + palette)
            _ = try await renderFixture(AnyView(NavigationStack { HealthView() }.preferredColorScheme(scheme)), name: "Health permission " + palette)
        }
    }

    private func renderFixture(_ content: AnyView, name: String) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }

    private func brightPixels(_ image: UIImage, area: CGRect) -> Int {
        // Crop in the screenshot's pixel coordinates before drawing into a
        // bitmap context, whose vertical axis can differ from UIKit's.
        guard let source = image.cgImage else { return 0 }
        let scale = CGFloat(source.width) / image.size.width
        let pixelsArea = CGRect(x: area.minX * scale, y: area.minY * scale,
                                width: area.width * scale, height: area.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !pixelsArea.isEmpty, let cg = source.cropping(to: pixelsArea) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let context = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var count = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                if pixels[i] > 180 && pixels[i + 1] > 180 && pixels[i + 2] > 180 { count += 1 }
            }
        }
        return count
    }

    func testContrastCropUsesTheTopOfTheScreenshotAtBothScales() {
        for scale in [CGFloat(1), CGFloat(2)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = scale
            let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
                UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
                UIColor.white.setFill(); context.fill(CGRect(x: 20, y: 10, width: 10, height: 10))
            }
            XCTAssertEqual(brightPixels(image, area: CGRect(x: 20, y: 10, width: 10, height: 10)), Int(100 * scale * scale))
            XCTAssertEqual(brightPixels(image, area: CGRect(x: 20, y: 80, width: 10, height: 10)), 0)
        }
    }

    func testMusicLinksAreRecognizedWithoutGenericPreviewCards() {
        let text = "https://example.com/a https://evil.music.apple.com/a https://music.apple.com/us/album/test/12?i=987 https://open.spotify.com/track/abc"
        let cards = ChatMusicShare.links(in:text)
        XCTAssertEqual(cards.count,1)
        XCTAssertEqual(cards[0]["appleMusicId"].string,"987")
        XCTAssertEqual(cards[0]["source"].string,"appleMusic")
        XCTAssertTrue(ChatMusicShare.links(in:"https://open.spotify.com/track/abc").isEmpty)
        XCTAssertEqual(ChatMusicShare.normalized(.object(["trackId":.string("apple-987")])).id,"apple-987")
        XCTAssertTrue(ChatMusicShare.links(in:"https://example.com").isEmpty)
    }
}
