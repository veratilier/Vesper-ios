import XCTest
import Combine
import SwiftUI
import UIKit
import WebKit
import CoreLocation
@testable import Vesper

private struct DesktopPalettePreview: View {
    @AppStorage("vesperPalette") private var paletteName = "blue"
    var body: some View {
        let palette = VesperPalette(rawValue: paletteName) ?? .blue
        NavigationStack {
            ZStack { Background(); HomeView(navigate: { _ in }) }
                .navigationTitle("Vesper").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .principal) { Text("Vesper").font(VesperTheme.title(32)) } }
        }.foregroundStyle(palette.ink).preferredColorScheme(palette == .black ? .dark : .light)
    }
}

private struct ControlsPalettePreview: View {
    let page: String
    var lyrics = false
    let onDock: (CGRect) -> Void
    @AppStorage("vesperPalette") private var paletteName = "white"
    var body: some View {
        TabView(selection: .constant(page == "Settings" ? 4 : 2)) {
            Text("Home").tabItem { Label("Home", systemImage: "house") }.tag(0)
            Text("Chat").tabItem { Label("Chat", systemImage: "bubble.left") }.tag(1)
            if page != "Settings" { preview.tabItem { Label("Collection", systemImage: "square.grid.2x2.fill") }.tag(2) }
            else { Text("Collection").tabItem { Label("Collection", systemImage: "square.grid.2x2.fill") }.tag(2) }
            Text("Letters").tabItem { Label("Letters", systemImage: "envelope") }.tag(3)
            if page == "Settings" { preview.tabItem { Label("Setting", systemImage: "gearshape") }.tag(4) }
            else { Text("Settings").tabItem { Label("Setting", systemImage: "gearshape") }.tag(4) }
        }
            .foregroundStyle((VesperPalette(rawValue: paletteName) ?? .white).ink)
            .tint((VesperPalette(rawValue: paletteName) ?? .white).ink)
            .preferredColorScheme(paletteName == "black" ? .dark : .light)
    }
    private var preview: some View {
        NavigationStack {
                ZStack {
                    Background()
                    if page == "Music" { MusicView(showingLyrics: lyrics, observeDock: onDock) }
                    else if page == "Settings" { SettingsView() }
                    else { ScrollView { VesperAppGrid(editing: .constant(false), open: { _ in }).padding(18) } }
                }.navigationTitle(page).navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { AppearancePicker() } }
        }
    }
}

private struct SurfacePalettePreview: View {
    let page: String
    let catalog: MusicCatalog
    @AppStorage("vesperPalette") private var paletteName = "white"
    var body: some View {
        NavigationStack {
            ZStack {
                Background()
                if page == "MyMusic" { MusicLibraryView(catalog: catalog, preview: true) }
                else if page == "Contacts" { NativeChatHome() }
                else if page == "Notes" { CollectionView(kind: .notes) }
                else { GlassCard { VStack(alignment: .leading) { Text("Glass panels").font(.headline); FormField(label: "Search", text: .constant("")); Button("Add") {} } }.padding(20) }
            }
        }.foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            .preferredColorScheme(paletteName == "black" ? .dark : .light)
    }
}

private final class DesktopContactProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "desktop-preview.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"conversations":[{"id":"main","title":"Rowan","preview":"今天的小事，也可以慢慢说。"},{"id":"reading","title":"一起读书","preview":"留在这里的几页书。"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class RedesignTests: XCTestCase {
    func testLibraryRowsAndSecondarySurfacesUseDockGlass() async throws {
        let previous = UserDefaults.standard.string(forKey: "vesperPalette")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "vesperPalette") } else { UserDefaults.standard.removeObject(forKey: "vesperPalette") } }
        URLProtocol.registerClass(DesktopContactProtocol.self)
        defer { URLProtocol.unregisterClass(DesktopContactProtocol.self) }
        let store = AppStore(); store.token = ""; store.baseURL = "https://desktop-preview.example"; store.historyURL = "https://desktop-preview.example"
        let chat = ChatSession(); chat.configure(store)
        store.documents["profile"] = .object(["agentName": .string("Rowan")])
        store.documents["notes"] = .array([.object(["id": .string("glass-note"), "text": .string("今天的小事，也可以慢慢说。"), "kind": .string("agent")])])
        store.documents["musicPlaylists"] = .array([.object(["id": .string("vesper-preview"), "name": .string("夜里，慢慢听"), "tracks": .array([.object(["id": .string("song"), "title": .string("天天")])])])])
        let player = MusicPlayer(), catalog = MusicCatalog()
        catalog.playlists = ["Favourite Songs", "kpop", "Recent", "深夜 R&B"].enumerated().map { .object(["id": .string("preview-\($0.offset)"), "name": .string($0.element)]) }
        catalog.connected = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for palette in ["white", "blue", "black"] {
            UserDefaults.standard.set(palette, forKey: "vesperPalette")
            for page in ["MyMusic", "Contacts", "Notes", "Panels"] {
                store.token = page == "Contacts" ? "preview-contact-token" : ""
                store.error = nil; chat.error = nil
                if page == "Contacts" { chat.configure(store) }
                let content = SurfacePalettePreview(page: page, catalog: catalog).environmentObject(store).environmentObject(chat).environmentObject(player)
                let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
                window.rootViewController = UIHostingController(rootView: content); window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(600))
                window.rootViewController?.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "Surfaces-\(page)-\(palette)"; attachment.lifetime = .keepAlways; add(attachment)
                window.isHidden = true; window.rootViewController = nil
            }
        }
    }
    func testControlGlassAndPlaybackDockRemainAboveTheTabBar() async throws {
        let suite = "controls-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "music.lyricsFrostedBackground")
        let store = AppStore(); store.token = ""
        let player = MusicPlayer(), chat = ChatSession()
        player.setQueue([.object(["id": .string("preview-song"), "title": .string("天天"), "artist": .string("陶喆"), "album": .string("I'm O.K."), "duration": .number(255),
            "lyrics": .array((0..<24).map { .object(["time": .number(Double($0 * 10)), "text": .string($0.isMultiple(of: 2) ? "我想要你在我身边" : "分享生命中的一切")]) })])])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(page: String, palette: String, size: CGSize, lyrics: Bool = false) async throws -> CGRect {
            preferences.set(palette, forKey: "vesperPalette")
            var dock = CGRect.zero
            let content = ControlsPalettePreview(page: page, lyrics: lyrics, onDock: { dock = $0 })
                .environmentObject(store).environmentObject(player).environmentObject(chat).defaultAppStorage(preferences)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView: content); window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(700))
            window.rootViewController?.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let label = "Controls-\(page)-\(palette)-\(Int(size.width))-\(lyrics ? "lyrics" : "cover")"
            let attachment = XCTAttachment(image: image); attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
            if page == "Music" {
                XCTAssertGreaterThan(dock.height, 90)
                XCTAssertLessThanOrEqual(dock.maxY, size.height - 88, "Playback controls must clear the floating tab bar")
            }
            return dock
        }
        for palette in ["white", "blue", "black"] {
            _ = try await capture(page: "Settings", palette: palette, size: CGSize(width: 393, height: 852))
            _ = try await capture(page: "Collection", palette: palette, size: CGSize(width: 393, height: 852))
        }
        for size in [CGSize(width: 393, height: 852), CGSize(width: 320, height: 668)] {
            let cover = try await capture(page: "Music", palette: "white", size: size)
            let lyrics = try await capture(page: "Music", palette: "white", size: size, lyrics: true)
            XCTAssertEqual(cover.minY, lyrics.minY, accuracy: 1, "Changing to lyrics must not move playback controls")
            XCTAssertEqual(cover.height, lyrics.height, accuracy: 1)
        }
    }
    func testExistingDesktopUpdatesWhenSwitchingAllThreePalettes() async throws {
        // Isolate appearance settings from the app's real icon-changing observer.
        let suite = "desktop-theme-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("white", forKey: "vesperPalette")
        let store = AppStore(); store.token = ""
        store.documents["notes"] = .array([.object(["id": .string("theme-letter"), "kind": .string("agent"),
            "text": .string("有些晚安会被卡住的声音打断，但不必把每一次没能顺利说出口的话，都当作一个需要当夜解决的问题。可以先休息，等醒来再慢慢说。"),
            "createdAt": .string("2026-10-03T04:00:00Z")])])
        store.documents["todos"] = .array([.object(["id": .string("theme-reminder"), "title": .string("整理后端")])])
        let future = Calendar.current.date(byAdding: .day, value: 24, to: .now)!
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
        store.documents["anniversaries"] = .array([.object(["id": .string("theme-date"), "title": .string("Birthday"), "date": .string(date.string(from: future))])])
        let player = MusicPlayer(), chat = ChatSession()
        chat.usage = .object(["rateLimits": .object(["secondary": .object(["usedPercent": .number(11), "windowDurationMins": .number(10080)])])])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func makeWindow() -> UIWindow {
            let content = DesktopPalettePreview().environmentObject(store).environmentObject(player).environmentObject(chat).defaultAppStorage(preferences)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 844)
            window.rootViewController = UIHostingController(rootView: content); window.makeKeyAndVisible()
            return window
        }
        func capture(_ window: UIWindow) -> UIImage {
            window.rootViewController?.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        }
        func pixels(_ image: UIImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 96 * 208 * 4)
            let source = try XCTUnwrap(image.cgImage)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 96, height: 208, bitsPerComponent: 8,
                    bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(source, in: CGRect(x: 0, y: 0, width: 96, height: 208))
            }
            return bytes
        }
        let live = makeWindow()
        defer { live.isHidden = true; live.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        // Keep the same Home instance alive through both directions of each transition.
        for (index, palette) in ["black", "white", "blue", "black", "blue", "white"].enumerated() {
            preferences.set(palette, forKey: "vesperPalette")
            live.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            let changed = capture(live)
            let fresh = makeWindow()
            try await Task.sleep(for: .milliseconds(500))
            let expected = capture(fresh)
            fresh.isHidden = true; fresh.rootViewController = nil
            let a = try pixels(changed), b = try pixels(expected)
            // A clear paper margin, away from glyphs, verifies real dark/light contrast.
            let margin = (70 * 96 + 7) * 4
            let brightness = (Double(a[margin]) + Double(a[margin + 1]) + Double(a[margin + 2])) / (3 * 255)
            if palette == "black" { XCTAssertLessThan(brightness, 0.4, "Dark paper must change with the theme") }
            else { XCTAssertGreaterThan(brightness, 0.65, "Light paper must change with the theme") }
            let difference = a.indices.filter { $0 % 4 != 3 }.reduce(0.0) { $0 + Double(abs(Int(a[$1]) - Int(b[$1]))) } / Double(96 * 208 * 3 * 255)
            XCTAssertLessThan(difference, 0.015, "Switching to \(palette) must match opening directly in that palette")
            let attachment = XCTAttachment(image: changed)
            attachment.name = "Home-live-theme-\(index)-\(palette)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testWeatherPermissionStopsRequestsBeforeTransport() async throws {
        var calls = 0
        for (enabled, authorized) in [(false, true), (true, false), (false, false)] {
            do {
                _ = try await WeatherService.load(enabled: enabled, authorized: authorized, latitude: 52.52, longitude: 13.41) { _ in
                    calls += 1
                    throw ServiceError(message: "Must not request")
                }
                XCTFail("Weather must require both permissions")
            } catch { }
        }
        XCTAssertEqual(calls, 0)
        XCTAssertThrowsError(try WeatherService.url(enabled: true, authorized: true, latitude: .nan, longitude: 13))
        XCTAssertThrowsError(try WeatherService.url(enabled: true, authorized: true, latitude: 91, longitude: 13))
        let url = try WeatherService.url(enabled: true, authorized: true, latitude: 52.521234, longitude: 13.412345)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "latitude" }?.value, "52.52")
        XCTAssertEqual(query.first { $0.name == "longitude" }?.value, "13.41")
    }

    func testWeatherForecastKeepsMissingValuesAndTimezone() async throws {
        let data = Data(#"{"timezone":"Asia/Shanghai","current":{"time":100000,"temperature_2m":18.4,"weather_code":2,"is_day":0,"relative_humidity_2m":null},"hourly":{"time":[90000,100000,103600,107200],"temperature_2m":[20,18,null,19],"weather_code":[0,2,3],"precipitation_probability":[0,null]},"daily":{"time":[100000,186400],"temperature_2m_min":[12,null],"temperature_2m_max":[24,25],"weather_code":[2,3]}}"#.utf8)
        let snapshot = try await WeatherService.load(enabled: true, authorized: true, latitude: 52.52, longitude: 13.41, now: Date(timeIntervalSince1970: 100000)) { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(snapshot.temperature, 18.4)
        XCTAssertEqual(snapshot.timeZone.identifier, "Asia/Shanghai")
        XCTAssertEqual(snapshot.icon, "cloud.moon")
        XCTAssertNil(snapshot.humidity)
        XCTAssertNil(snapshot.feelsLike)
        XCTAssertEqual(snapshot.hours.count, 1)
        XCTAssertNil(snapshot.hours.first?.rainChance)
        XCTAssertEqual(snapshot.days.count, 1)
        XCTAssertThrowsError(try WeatherSnapshot.parse(.object([:])))
    }

    func testHomeCountdownUsesEnglish() {
        XCTAssertEqual(HomeDesktopContent.countdown(24), "In 24 days")
        XCTAssertEqual(HomeDesktopContent.countdown(1), "In 1 day")
        XCTAssertEqual(HomeDesktopContent.countdown(0), "Today")
        XCTAssertEqual(HomeDesktopContent.countdown(-1), "1 day ago")
        XCTAssertEqual(HomeDesktopContent.countdown(-24), "24 days ago")
    }

    func testBundledPhotoStackTurnsBothWaysFlingsCancelsAndOpensCurrentPhoto() async throws {
        let web = PhotoStackSurface()
        var opened: Int?
        var changed = 0
        let coordinator = PhotoStackWebView.Coordinator(onChange: { changed = $0 }, onTap: { opened = $0 })
        coordinator.webView = web; web.navigationDelegate = coordinator
        web.configuration.userContentController.add(coordinator, name: "photoStack")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        web.frame = CGRect(x: 20, y: 200, width: 320, height: 226); host.view.addSubview(web)
        defer {
            PhotoStackWebView.dismantleUIView(web, coordinator: coordinator)
            window.isHidden = true; window.rootViewController = nil
        }
        let urls = [UIColor.systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple].map { color in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 150, height: 200)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
            }
            return "data:image/png;base64," + image.pngData()!.base64EncodedString()
        }
        web.configure(urls: urls, reducedMotion: false)
        var mounted = false
        for _ in 0..<60 {
            if (try? await web.evaluateJavaScript("typeof window.stack !== 'undefined'")) as? Bool == true { mounted = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(mounted, "The bundled upstream JS must load in WKWebView")
        guard mounted else { return }
        func waitForSettlement() async throws {
            for _ in 0..<50 {
                if try await web.evaluateJavaScript("stack._anim===null") as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("Photo turn did not settle")
        }
        let layers = try await web.evaluateJavaScript("stack.cards.filter(c=>c.style.opacity==='1').length") as? Int
        XCTAssertEqual(layers, 3)
        _ = try await web.evaluateJavaScript("stack.goto(2)")
        let reversible = try await web.evaluateJavaScript("(()=>{stack._scrub(-1,.3);const a=stack.cards.map(c=>c.style.transform).join('|');stack._scrub(-1,.7);stack._scrub(-1,.3);return a===stack.cards.map(c=>c.style.transform).join('|')})()") as? Bool
        XCTAssertEqual(reversible, true)
        _ = try await web.evaluateJavaScript("stack._release(-12,200,-1)")
        try await waitForSettlement()
        let flingIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(flingIndex, 3)
        _ = try await web.evaluateJavaScript("stack.prev()")
        try await waitForSettlement()
        let previousIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(previousIndex, 2)
        _ = try await web.evaluateJavaScript("stack.stage.setPointerCapture=()=>{};stack.stage.dispatchEvent(new PointerEvent('pointerdown',{pointerId:1,clientX:200,clientY:100}));stack.stage.dispatchEvent(new PointerEvent('pointermove',{pointerId:1,clientX:140,clientY:102}));stack.stage.dispatchEvent(new PointerEvent('pointercancel',{pointerId:1}));")
        let cancelledIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(cancelledIndex, 2)
        _ = try await web.evaluateJavaScript("stack.stage.dispatchEvent(new MouseEvent('click'))")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(opened, 2); XCTAssertEqual(changed, 2)
        _ = try await web.evaluateJavaScript("stack.goto(4);stack.next();")
        let lastIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(lastIndex, 4)
        _ = try await web.evaluateJavaScript("stack.goto(0);stack.prev();")
        let firstIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(firstIndex, 0)
        web.configure(urls: urls, reducedMotion: true)
        _ = try await web.evaluateJavaScript("stack.next()")
        let reducedIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(reducedIndex, 1)
        web.configure(urls: urls, reducedMotion: true)
        let preservedIndex = try await web.evaluateJavaScript("stack.index") as? Int
        XCTAssertEqual(preservedIndex, 1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        attachment.name = "Collection-PhotoStack-upstream"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWeatherPageRendersForecastAndDisabledAccess() async throws {
        let weather = WeatherController()
        try await Task.sleep(for: .milliseconds(150))
        let now = Date.now
        let forecast = WeatherSnapshot(temperature: 18, code: 2, isDay: true, feelsLike: 17, humidity: 70, wind: 8,
            updatedAt: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            hours: (0..<24).map { .init(date: now.addingTimeInterval(Double($0)*3600), temperature: Double(18 + $0 % 5), code: 2, rainChance: 20) },
            days: (0..<7).map { .init(date: now.addingTimeInterval(Double($0)*86400), low: 14, high: 24, code: $0 % 2 == 0 ? 2 : 61, rainChance: 30) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for populated in [true, false] {
            weather.snapshot = populated ? forecast : nil
            let host = UIHostingController(rootView: NavigationStack { WeatherView(weather: weather) }.foregroundStyle(VesperTheme.ink))
            let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .light
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            attachment.name = populated ? "Collection-Weather-forecast" : "Collection-Weather-access"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }

    func testDesktopLetterUsesLatestNonemptyRowanNote() {
        func note(_ id: String, _ kind: String, _ date: String, _ text: String = "A letter") -> JSONValue {
            .object(["id": .string(id), "kind": .string(kind), "createdAt": .string(date), "text": .string(text)])
        }
        let notes = [note("old", "agent", "2026-10-01T10:00:00Z"),
                     note("vera", "user", "2026-10-05T10:00:00Z"),
                     note("new", "agent", "2026-10-04T10:00:00.500Z"),
                     note("empty", "agent", "2026-10-05T11:00:00Z", "  ")]
        XCTAssertEqual(HomeDesktopContent.latestRowanNote(notes)?.id, "new")
        XCTAssertNil(HomeDesktopContent.latestRowanNote([notes[1], notes[3]]))
        var fallback = note("updated", "agent", "invalid")
        fallback["updatedAt"] = .string("2026-10-04T12:00:00Z")
        XCTAssertEqual(HomeDesktopContent.latestRowanNote(notes + [fallback])?.id, "updated")
    }

    func testDesktopDatePicksNextOccurrenceAndSkipsInvalidDates() throws {
        let now = try XCTUnwrap(DateCounter.baseDate(.object(["date": .string("2026-10-05")])))
        func item(_ id: String, _ date: String, _ repeating: Bool = false) -> JSONValue {
            .object(["id": .string(id), "date": .string(date), "repeats": .bool(repeating)])
        }
        let items = [item("past", "2026-10-01"), item("later", "2026-12-01"),
                     item("annual", "2020-10-17", true), item("invalid", "not a date")]
        XCTAssertEqual(HomeDesktopContent.nextDate(items, now: now)?.id, "annual")
        XCTAssertEqual(HomeDesktopContent.nextDate(items + [item("today", "2026-10-05")], now: now)?.id, "today")
        XCTAssertEqual(HomeDesktopContent.nextDate([items[0], items[3]], now: now)?.id, "past")
        XCTAssertNil(HomeDesktopContent.nextDate([items[3]], now: now))
    }

    func testContactGreetingsRotateWithinLocalPoolAndCanReturnLater() {
        XCTAssertTrue(ChatWelcomeLines.all.contains("A place for today, too."))
        for line in ChatWelcomeLines.all {
            let next = ChatWelcomeLines.next(after: line)
            XCTAssertTrue(ChatWelcomeLines.all.contains(next))
            XCTAssertNotEqual(next, line)
        }
    }

    func testDesktopPhoneLayoutsWithLetterAndAccessibilityText() async throws {
        let store = AppStore()
        store.token = ""
        store.connected = true
        store.documents["notes"] = .array([.object([
            "id": .string("desktop-letter"), "kind": .string("agent"),
            "text": .string("有些晚安会被卡住的声音打断，但不必把每一次没能顺利说出口的话，都当作一个需要当夜解决的问题。"),
            "createdAt": .string("2026-10-05T04:00:00Z")])])
        store.documents["todos"] = .array([.object(["id": .string("todo-1"), "title": .string("整理后端")]),
                                           .object(["id": .string("todo-2"), "title": .string("读几页书")])])
        let future = Calendar.current.date(byAdding: .day, value: 12, to: .now)!
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        store.documents["anniversaries"] = .array([.object(["id": .string("date-1"), "title": .string("我们的日子"), "date": .string(formatter.string(from: future))])])
        let player = MusicPlayer()
        player.track = .object(["id": .string("fixture-song"), "title": .string("Bloom"), "artist": .string("The Paper Kites")])
        let chat = ChatSession()
        chat.usage = .object(["rateLimits": .object(["secondary": .object(["usedPercent": .number(10), "windowDurationMins": .number(10080)])])])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (width, textSize, label) in [(CGFloat(393), DynamicTypeSize.large, "phone"),
                                      (CGFloat(320), DynamicTypeSize.large, "small-phone"),
                                      (CGFloat(393), DynamicTypeSize.accessibility3, "large-text")] {
            let content = NavigationStack {
                ZStack { Background(); HomeView(navigate: { _ in }) }
                    .navigationTitle("Vesper").navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) {
                        HStack { ForEach(["Home", "Chat", "Collection", "Journal", "Setting"], id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity) } }
                            .frame(height: 58).padding(.horizontal, 12).background(.regularMaterial, in: Capsule()).padding(12)
                    }
                    .toolbar { ToolbarItem(placement: .principal) { Text("Vesper").font(VesperTheme.title(32)) } }
            }.environmentObject(store).environmentObject(player).environmentObject(chat)
                .environment(\.dynamicTypeSize, textSize).foregroundStyle(VesperTheme.ink)
            let host = UIHostingController(rootView: content)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 780)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(450))
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.width, width)
            XCTAssertNotNil(UIImage(named: "LetterPaper"))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Home-desktop-" + label; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }

    func testContactWelcomeRendersBelowRowsInRemainingSpace() async throws {
        URLProtocol.registerClass(DesktopContactProtocol.self)
        defer { URLProtocol.unregisterClass(DesktopContactProtocol.self) }
        let store = AppStore()
        store.token = "synthetic-preview-token"
        store.historyURL = "https://desktop-preview.example/history"
        let chat = ChatSession()
        let host = UIHostingController(rootView: NativeChatHome().environmentObject(store).environmentObject(chat))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; chat.disconnect() }
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(650))
        host.view.layoutIfNeeded()
        XCTAssertEqual(chat.conversations.count, 2)
        XCTAssertNil(chat.error)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Chat-contact-welcome"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testReadingPaginationKeepsAllTextAndFitsPortraitAndLandscape() {
        let source = "# 第一章\n" + String(repeating: "长段落必须完整换行，不能被裁掉。🙂这是一段用于检查分页的测试文字。", count: 60) + "\n# 第二章\n" + String(repeating: "第二章的内容也应保留。\n", count: 30)
        for (size, fontSize) in [(CGSize(width: 300, height: 450), CGFloat(18)), (CGSize(width: 600, height: 190), CGFloat(24))] {
            let result = ReadingLayout.pages(in: source, width: size.width, height: size.height, fontSize: fontSize)
            XCTAssertGreaterThan(result.pages.count, 1)
            XCTAssertEqual(result.pages.map(\.text).joined(), source)
            var end = 0
            for page in result.pages {
                XCTAssertEqual(page.range.location, end)
                end = NSMaxRange(page.range)
                let view = UITextView(usingTextLayoutManager: false)
                view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
                view.frame = CGRect(origin: .zero, size: size)
                view.attributedText = NSAttributedString(string: page.text, attributes: ReadingLayout.attributes(fontSize: fontSize))
                view.layoutManager.ensureLayout(for: view.textContainer)
                XCTAssertLessThanOrEqual(view.layoutManager.usedRect(for: view.textContainer).maxY, size.height + 1)
            }
            XCTAssertEqual(end, source.utf16.count)
        }
    }

    func testReadingRoomTextStaysInsidePhonePage() async throws {
        let store = AppStore()
        store.token = ""
        let paragraph = "这是共读室的排版验证。长段落应该在书页内自然换行，左右边缘必须完整可见，不能被裁掉。阅读时每一行应当连续，翻到下一页也不能漏字。"
        store.documents["readingRoom"] = .array([.object(["id": .string("layout-fixture"), "title": .string("共读室排版验证"), "text": .string(String(repeating: paragraph + "\n\n", count: 40)), "notes": .array([]), "page": .number(0)])])
        let host = UIHostingController(rootView: NavigationStack { ReaderView(bookID: "layout-fixture") }.environmentObject(store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
        window.backgroundColor = .systemBackground
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(800))
        host.view.layoutIfNeeded()
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let views = textViews(host.view)
        XCTAssertFalse(views.isEmpty)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Reading-room-phone-layout"; attachment.lifetime = .keepAlways; add(attachment)
        for view in views {
            XCTAssertLessThanOrEqual(view.bounds.width, 393 - 32, "Text must use the viewport width, not its unwrapped intrinsic width")
            view.layoutManager.ensureLayout(for: view.textContainer)
            let used = view.layoutManager.usedRect(for: view.textContainer)
            XCTAssertLessThanOrEqual(used.maxX, view.bounds.width + 1)
            XCTAssertLessThanOrEqual(used.maxY, view.bounds.height + 1, "Pagination must fit the actual visible height")
        }
    }

    func testLargeTranscriptPresentationBudgetAndStableRows() {
        let messages: [JSONValue] = (0..<1000).map { i in
            .object(["id": .string("m\(i)"), "role": .string(i % 5 == 0 ? "user" : (i % 5 == 4 ? "agent" : "system")),
                     "createdAt": .string("2026-09-29T10:00:00Z"), "content": .string("Test"),
                     "metadata": .object(["turnId": .string("t\(i / 5)")])])
        }
        let expected = ChatPresentation.displayRows(messages)
        XCTAssertEqual(expected.count, 400)
        XCTAssertEqual(expected.filter { !$0.activities.isEmpty }.count, 200)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            let rows = ChatPresentation.displayRows(messages)
            XCTAssertEqual(rows.map(\.id), expected.map(\.id))
            XCTAssertEqual(rows.flatMap(\.activities).count, 600)
        }
        let elapsed = start.duration(to: .now)
        print("CHAT_PRESENTATION_1000_ROWS_20_PASSES: \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testAppleMusicQueueIncludesFollowingSongsAndSkipsLegacyCards() {
        func song(_ id: String) -> JSONValue { .object(["id": .string("apple-" + id), "source": .string("appleMusic"), "appleMusicId": .string(id)]) }
        let queue = [song("one"), .object(["id": .string("legacy"), "neteaseId": .string("123")]), song("two"), song("one"), song("three"), song("")]
        XCTAssertEqual(MusicPlayer.playableIDs(queue), ["one", "two", "three"])
        XCTAssertEqual(MusicPlayer.playableIDs([]), [])
    }

    func testNativeAdapterPreservesRemoteConnectionsAndRejectsUnknownTools() throws {
        let remote: JSONValue = .object(["connectionId": .string("remote"), "tools": .array([])])
        let catalog = NativeDeviceTools.addToCatalog(.object(["connections": .array([remote])]))
        XCTAssertEqual(catalog["connections"].array.first, remote)
        XCTAssertEqual(NativeDeviceTools.addToCatalog(catalog), catalog)
        XCTAssertEqual(catalog["connections"].array.last?["tools"].array.count, 5)
        let args: JSONValue = .object(["connectionId": .string(NativeDeviceTools.connectionID), "toolName": .string("read_native_calendar"), "arguments": .object([:])])
        XCTAssertEqual(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: args), "read_native_calendar")
        var invalid = args; invalid["toolName"] = .string("delete_event")
        XCTAssertThrowsError(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: invalid))
        invalid = args; invalid["arguments"] = .object(["allHistory": .bool(true)])
        XCTAssertThrowsError(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: invalid))
        invalid = args; invalid["connectionId"] = .string("remote")
        XCTAssertNil(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: invalid))
        XCTAssertEqual(try NativeDeviceTools.resolve(name: "read_native_health", arguments: .object([:])), "read_native_health")
        XCTAssertEqual(try NativeToolCatalog.normalize([NativeDeviceTools.calendarTool, NativeDeviceTools.healthTool]).count, 2)
    }
    func testCurrentLocationKeepsCoordinatesAccuracyAndFreshness() throws {
        let now = Date(timeIntervalSince1970: 1791187200)
        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.275123, longitude: 120.742456), altitude: 0, horizontalAccuracy: 12, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-2))
        let result = try NativeChatLocation.snapshot(location, precise: true, now: now)
        XCTAssertEqual(result["latitude"].number, 31.275123, accuracy: 0.0000001)
        XCTAssertEqual(result["longitude"].number, 120.742456, accuracy: 0.0000001)
        XCTAssertEqual(result["horizontalAccuracyMeters"].number, 12)
        XCTAssertEqual(result["ageSeconds"].number, 2)
        XCTAssertEqual(result["precisePermission"], .bool(true))
        XCTAssertThrowsError(try NativeChatLocation.snapshot(location, precise: true, now: now.addingTimeInterval(60)))
        let approximate = try NativeChatLocation.snapshot(location, precise: false, now: now)
        XCTAssertEqual(approximate["precisePermission"], .bool(false))
        let invalid = CLLocation(coordinate: location.coordinate, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: now)
        XCTAssertThrowsError(try NativeChatLocation.snapshot(invalid, precise: true, now: now))
        let wrapped: JSONValue = .object(["connectionId": .string(NativeDeviceTools.connectionID), "toolName": .string("read_native_location"), "arguments": .object([:])])
        XCTAssertEqual(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: wrapped), "read_native_location")
        var unexpected = wrapped; unexpected["arguments"] = .object(["backgroundTracking": .bool(true)])
        XCTAssertThrowsError(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: unexpected))
    }

    func testNativePlannerWriteValidatesDatesAndOldThreadDiscovery() throws {
        let event: JSONValue = .object(["kind": .string("event"), "title": .string("Study"), "start": .string("2026-10-06T09:00:00+08:00"), "end": .string("2026-10-06T10:00:00+08:00"), "requestId": .string("fixture-event")])
        let parsed = try SystemPlanner.writeRequest(event)
        XCTAssertEqual(parsed.end!.timeIntervalSince(parsed.start!), 3600)
        let wrapped: JSONValue = .object(["connectionId": .string(NativeDeviceTools.connectionID), "toolName": .string("create_native_planner_item"), "arguments": event])
        XCTAssertEqual(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: wrapped), "create_native_planner_item")
        XCTAssertEqual(try NativeToolCatalog.normalize([NativeDeviceTools.plannerWriteTool]).count, 1)
        var invalid = event; invalid["end"] = event["start"]
        XCTAssertThrowsError(try SystemPlanner.writeRequest(invalid))
        invalid = event; invalid["start"] = .string("tomorrow morning")
        XCTAssertThrowsError(try SystemPlanner.writeRequest(invalid))
        invalid = event; invalid["requestId"] = .string("")
        XCTAssertThrowsError(try SystemPlanner.writeRequest(invalid))
        let reminder: JSONValue = .object(["kind": .string("reminder"), "title": .string("Bring notebook"), "requestId": .string("fixture-reminder")])
        XCTAssertNil(try SystemPlanner.writeRequest(reminder).start)
        var timed = reminder; timed["start"] = event["start"]
        XCTAssertNotNil(try SystemPlanner.writeRequest(timed).start)
        timed["end"] = event["end"]
        XCTAssertThrowsError(try SystemPlanner.writeRequest(timed))
    }

    func testExistingChatDiscoversHealthArgumentsAndVesperAlarms() throws {
        var args: JSONValue = .object(["connectionId": .string(NativeDeviceTools.connectionID), "toolName": .string("read_native_health"), "arguments": .object(["metrics": .array([.string("catalog")])])])
        XCTAssertEqual(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: args), "read_native_health")
        args["arguments"] = .object(["metrics": .string("all")])
        XCTAssertThrowsError(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: args))
        args["toolName"] = .string("manage_native_alarm")
        args["arguments"] = .object(["action": .string("list")])
        XCTAssertEqual(try NativeDeviceTools.resolve(name: "call_configured_mcp_tool", arguments: args), "manage_native_alarm")
        XCTAssertEqual(try NativeToolCatalog.normalize([NativeDeviceTools.alarmTool]).count, 1)
    }
    func testCalendarDeniedAccessNeverQueriesEvents() {
        XCTAssertThrowsError(try SystemPlanner.calendarSnapshot(authorized: false, now: Date()) { _, _ in
            XCTFail("Denied calendar access must not query the store"); return []
        })
    }
    func testCalendarReadIsBoundedAndEmptyIsDistinctFromDenied() throws {
        let now = Date(timeIntervalSince1970: 1790560000)
        let result = try SystemPlanner.calendarSnapshot(authorized: true, now: now) { start, end in
            XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: end).day, 7)
            return (0..<105).map { .object(["title": .string("Test event \($0)")]) }
        }
        XCTAssertEqual(result["events"].array.count, 100)
        XCTAssertEqual(result["hasMore"], .bool(true))
        let empty = try SystemPlanner.calendarSnapshot(authorized: true, now: now) { _, _ in [] }
        XCTAssertEqual(empty["events"], .array([]))
        XCTAssertEqual(empty["hasMore"], .bool(false))
    }

    func testStartupAutomaticallyRetriesTemporaryFailuresAndUnlocksEntry() async {
        var attempts = 0
        let store = AppStore(loadState: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            if attempts == 2 { throw ServiceError(message: "Busy", statusCode: 503) }
            return .object(["documents": .object([:])])
        }, retryDelay: {})
        store.token = "test-token"
        await store.refresh(retryTransientFailures: true)
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.connectionError)
    }

    func testStartupDoesNotRetryRejectedCredentials() async {
        var attempts = 0
        let store = AppStore(loadState: { _ in
            attempts += 1
            throw ServiceError(message: "HTTP 401: Unauthorized", statusCode: 401)
        }, retryDelay: {})
        store.token = "test-token"
        await store.refresh(retryTransientFailures: true)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(store.connected)
        XCTAssertEqual(store.connectionError, "HTTP 401: Unauthorized")
    }

    func testStartupRetriesAreBoundedAndReportFinalFailure() async {
        var attempts = 0
        let store = AppStore(loadState: { _ in
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }, retryDelay: {})
        store.token = "test-token"
        await store.refresh(retryTransientFailures: true)
        XCTAssertEqual(attempts, 3)
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.loading)
        XCTAssertNotNil(store.connectionError)
    }

    func testCancelledRefreshDoesNotInvalidateSuccessfulConnection() async {
        let store = AppStore(loadState: { _ in throw URLError(.cancelled) })
        store.token = "test-token"
        store.connected = true
        await store.refresh()
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.connectionError)
    }

    func testForegroundConnectionWaitsForCancelledStartupToFinish() async {
        var pending: CheckedContinuation<JSONValue, Error>?
        var attempts = 0
        let store = AppStore(loadState: { _ in
            attempts += 1
            if attempts == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return .object(["documents": .object([:])])
        }, retryDelay: {})
        store.token = "test-token"
        let first = Task { await store.refresh(retryTransientFailures: true) }
        while pending == nil { await Task.yield() }
        first.cancel()
        let resumed = Task { await store.refresh(retryTransientFailures: true) }
        await Task.yield()
        pending?.resume(throwing: URLError(.cancelled))
        await first.value
        await resumed.value
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(store.connected)
        XCTAssertNil(store.connectionError)
    }

    func testSuccessfulConnectionStillUnlocksEntryDuringConcurrentSave() async {
        var pending: CheckedContinuation<JSONValue, Error>?
        let store = AppStore(loadState: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        store.token = "test-token"
        store.documents = ["notes": .string("newer local value")]
        let connecting = Task { await store.refresh(retryTransientFailures: true) }
        while pending == nil { await Task.yield() }
        store.saving = true
        pending?.resume(returning: .object(["documents": .object(["notes": .object(["value": .string("older snapshot")])])]))
        await connecting.value
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.document("notes"), .string("newer local value"))
        XCTAssertNil(store.connectionError)
        store.saving = false
    }

    func testTranscriptPresentationSurvivesUnrelatedUpdatesAndRefreshesForMessageEdits() {
        let chat = ChatSession()
        chat.messages = [.object(["id": .string("reply"), "role": .string("assistant"), "content": .string("first")])]
        let first = chat.presentation
        for _ in 0..<200 { XCTAssertTrue(chat.presentation === first) }
        chat.error = "unrelated status"
        XCTAssertTrue(chat.presentation === first)
        chat.messages[0]["content"] = .string("streamed update")
        let updated = chat.presentation
        XCTAssertFalse(updated === first)
        XCTAssertEqual(updated.rows.first?.messages.first?["content"].string, "streamed update")
        XCTAssertEqual(updated.lastReplyID, "reply")
        chat.messages.removeAll()
        XCTAssertTrue(chat.presentation.rows.isEmpty)
        XCTAssertNil(chat.presentation.lastReplyID)
    }

    func testStartupWithoutCredentialsOffersSetupInsteadOfClaimingConnection() async {
        let store = AppStore()
        store.token = "  "
        await store.refresh()
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.loading)
        XCTAssertNotNil(store.connectionError)
        XCTAssertNil(store.error, "Startup failures should be inline, not repeated alerts.")
    }

    func testChangingConnectionInvalidatesPreviousSuccess() {
        let store = AppStore()
        store.connected = true
        store.baseURL = "https://different.example"
        XCTAssertFalse(store.connected)
        store.connected = true
        store.token = "different-token"
        XCTAssertFalse(store.connected)
    }

    func testInvalidConnectionCannotKeepEntryUnlocked() async {
        let store = AppStore()
        store.token = "test-token"
        store.baseURL = "not a URL"
        store.connected = true
        await store.connect()
        XCTAssertFalse(store.connected)
        XCTAssertNotNil(store.connectionError)
        XCTAssertFalse(store.loading)
    }

    func testDraftsSurviveShellAndConversationChanges() {
        let draft = ChatComposer()
        draft.draft = "unfinished main-room thought"
        draft.pendingMusic = .object(["id": .string("song")])
        draft.pendingSticker = .object(["assetId": .string("sticker")])
        draft.switchConversation(from: "main", to: "other")
        XCTAssertEqual(draft.draft, "")
        XCTAssertNil(draft.pendingMusic)
        XCTAssertNil(draft.pendingSticker)
        draft.draft = "another draft"
        draft.switchConversation(from: "other", to: "main")
        XCTAssertEqual(draft.draft, "unfinished main-room thought")
        XCTAssertEqual(draft.pendingMusic?["id"].string, "song")
        XCTAssertEqual(draft.pendingSticker?["assetId"].string, "sticker")
        draft.switchConversation(from: "main", to: "main")
        XCTAssertEqual(draft.draft, "unfinished main-room thought")
    }
    func testTypingOnlyUpdatesDraftObservers() {
        let composer = ChatComposer()
        var timelineInvalidations = 0
        var inputInvalidations = 0
        let timeline = composer.objectWillChange.sink { timelineInvalidations += 1 }
        let input = composer.text.objectWillChange.sink { inputInvalidations += 1 }
        withExtendedLifetime((timeline, input)) {
            for count in 1...200 { composer.draft = String(repeating: "字", count: count) }
            XCTAssertEqual(timelineInvalidations, 0, "Typing must not refresh the chat timeline.")
            XCTAssertEqual(inputInvalidations, 200)
            composer.images = [Data([1, 2, 3])]
            XCTAssertEqual(timelineInvalidations, 1, "Attachments should still refresh the composer.")
        }
    }
    func testNoteLayoutRoundTripDoesNotNeedOrChangeBody() {
        let note: JSONValue = .object(["id": .string("one"), "text": .string("original body"), "kind": .string("agent")])
        var placement = NotePlacement(note, index: 4)
        XCTAssertEqual(placement.cardStyle, "letter")
        placement.x = 460; placement.rotation = -7; placement.cardStyle = "grid"
        var changed = note; changed["layout"] = placement.json
        XCTAssertEqual(NotePlacement(changed, index: 0), placement)
        XCTAssertEqual(changed["text"], note["text"])
    }
}
