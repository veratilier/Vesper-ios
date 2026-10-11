import SwiftUI
import MusicKit

/// Select genuine shared content for the desktop; placeholder copy never becomes saved data.
enum HomeDesktopContent {
    static func nextDate(_ items: [JSONValue], now: Date = .now) -> JSONValue? {
        let valid = items.compactMap { item -> (JSONValue, Int)? in
            guard let days = DateCounter.days(item, now: now) else { return nil }
            return (item, days)
        }
        return valid.filter { $0.1 >= 0 }.min { $0.1 < $1.1 }?.0
            ?? valid.max { $0.1 < $1.1 }?.0
    }
    static func countdown(_ days: Int) -> String {
        days == 0 ? "Today" : days > 0 ? "In \(days) \(days == 1 ? "day" : "days")" : "\(abs(days)) \(days == -1 ? "day" : "days") ago"
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("vesperPalette") private var paletteName = "blue"
    @State private var refreshingUsage = false
    @State private var desireState: JSONValue = .null
    @ObservedObject private var weather = WeatherController.shared
    let navigate: (Destination) -> Void
    var showsInlineMusic = true
    private var palette: VesperPalette { VesperPalette(rawValue: paletteName) ?? .blue }

    var body: some View {
        GeometryReader { geometry in
            let width = max(240, min(geometry.size.width, 600) - 36)
            let photoHeight = min(265, max(214, (width - 14) * 0.55 + 22))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        header
                        usageLine
                    }
                    if typeSize.isAccessibilitySize || geometry.size.width < 350 {
                        desireCard(height: photoHeight)
                        dateLeaf
                        remindersSlip
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            desireCard(height: photoHeight).frame(width: (width - 14) * 0.60)
                            VStack(spacing: 12) {
                                dateLeaf.frame(maxHeight: .infinity)
                                remindersSlip.frame(maxHeight: .infinity)
                            }.frame(maxWidth: .infinity).frame(height: photoHeight)
                        }
                    }
                    if showsInlineMusic { musicRow }
                    if !store.connected && !store.hasLocalData {
                        Button("Connect Vesper in Settings") { navigate(.settings) }
                            .font(.footnote).foregroundStyle(palette.muted)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh(); await loadUsage(); await loadDesire(); weather.refresh(force: true) }
        }
        .foregroundStyle(palette.ink)
        .buttonStyle(.plain)
        .task {
            player.updateLibrary(store.document("music").array)
            await store.refresh(minimumInterval: 45)
            await loadUsage()
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                weather.refresh()
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
        .task(id: [store.api.baseURL, store.token, String(describing: phase)]) {
            desireState = DesireEmotion.cached(store.api)
            guard phase == .active, !store.token.isEmpty else { return }
            while !Task.isCancelled {
                await loadDesire()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onChange(of: store.document("music")) { _, tracks in player.updateLibrary(tracks.array) }
        .onChange(of: store.token) { _, _ in Task { await loadUsage() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    dateLabel
                    Spacer(minLength: 8)
                    weatherRow
                }
                VStack(alignment: .leading, spacing: 6) { dateLabel; weatherRow }
            }
            Text(greeting + ", " + userName)
                .font(VesperTheme.title(34)).minimumScaleFactor(0.65).lineLimit(1)
                .frame(height: typeSize.isAccessibilitySize ? nil : 46, alignment: .leading)
        }
    }
    private var dateLabel: some View {
        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .font(.system(.caption, design: .serif)).foregroundStyle(palette.muted)
            .fixedSize()
    }
    private var userName: String {
        let name = store.document("profile")["userName"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Vera" : name
    }
    private var usageLine: some View {
        NavigationLink { UsageView() } label: {
            HStack(spacing: 12) {
                Text("Weekly").font(.system(.caption, design: .serif))
                ProgressView(value: Double(remainingUsage ?? 0), total: 100)
                    .tint(palette.accent.opacity(0.75))
                    .opacity(remainingUsage == nil ? 0.35 : 1)
                Text(remainingUsage.map { "\($0)%" } ?? "—")
                    .font(.system(.caption, design: .serif)).monospacedDigit()
            }
            .foregroundStyle(palette.muted).frame(minHeight: 30)
        }
        .accessibilityLabel("Weekly usage")
        .accessibilityValue(remainingUsage.map { "\($0) percent remaining" } ?? "Unavailable")
        .accessibilityIdentifier("home-weekly-usage")
    }
    private func desireCard(height: CGFloat) -> some View {
        Button { navigate(.desire) } label: {
            DesireTide(values: DesireEmotion.fields.map { key, _ in
                if case .number(let value) = desireState["values"][key] { return value }
                return nil
            }, compact: true)
            .overlay(alignment: .topLeading) {
                HStack {
                    Text("Desire").font(VesperTheme.title(23)).minimumScaleFactor(0.6).lineLimit(1)
                    Spacer(minLength: 1)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }
                .foregroundStyle(palette == .black ? Color.white : Color(red: 0.16, green: 0.29, blue: 0.34))
                .padding(12)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .vesperGlass(in: RoundedRectangle(cornerRadius: 22))
        }.accessibilityLabel("Desire").accessibilityIdentifier("home-desire-tide")
    }
    private func loadDesire() async {
        let api = store.api
        guard !api.token.isEmpty else { return }
        guard let state = try? await DesireEmotion.refresh(api), !Task.isCancelled,
              api.baseURL == store.api.baseURL, api.token == store.token else { return }
        desireState = state
    }
    private var upcomingDate: JSONValue? { HomeDesktopContent.nextDate(store.document("anniversaries").array) }
    private var dateLeaf: some View {
        Button { navigate(.dates) } label: {
            VStack(spacing: 3) {
                if let item = upcomingDate, let target = DateCounter.target(item), let days = DateCounter.days(item) {
                    Text(target.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(.caption, design: .serif)).italic()
                    Text(target.formatted(.dateTime.day()))
                        .font(.system(size: 38, weight: .regular, design: .serif)).italic()
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Rectangle().fill(palette.muted.opacity(0.30)).frame(width: 52, height: 0.5)
                    Text(item["title"].string).font(.system(size: 10, design: .serif)).lineLimit(1)
                    Text(HomeDesktopContent.countdown(days))
                        .font(.system(.caption2, design: .serif)).lineLimit(1)
                } else {
                    Text("Dates").font(VesperTheme.title(25))
                    Text("留一个期待的日子").font(.system(.caption2, design: .serif))
                        .multilineTextAlignment(.center).padding(.top, 8)
                }
            }
            .foregroundStyle(palette.muted).padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .vesperGlass(in: RoundedRectangle(cornerRadius: 13))
        }
        .accessibilityLabel(upcomingDate.map { $0["title"].string + ", " + (DateCounter.days($0).map(HomeDesktopContent.countdown) ?? "") } ?? "Dates, add a date")
        .accessibilityIdentifier("home-date-leaf")
    }
    private var remindersSlip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { navigate(.reminders) } label: {
                Text("Reminders").font(VesperTheme.title(22)).foregroundStyle(palette.muted)
                    .minimumScaleFactor(0.65).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 26, alignment: .leading)
            }.accessibilityLabel("Open Reminders")
            Rectangle().fill(palette.muted.opacity(0.20)).frame(height: 0.5)
            let todos = store.document("todos").array.filter { !$0["done"].bool }
            if todos.isEmpty {
                Button { navigate(.reminders) } label: {
                    Text("今天，慢慢来。")
                        .font(.system(.caption, design: .serif)).foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            } else {
                ForEach(Array(todos.prefix(2))) { item in
                    Button {
                        Task {
                            var changed = item; changed["done"] = .bool(true)
                            _ = await store.upsert("todos", item: changed)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(palette.muted)
                            Text(item["title"].string).font(.system(.caption, design: .serif))
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }.frame(minHeight: 30)
                    }.disabled(store.saving).accessibilityLabel("Complete reminder: " + item["title"].string)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vesperGlass(in: RoundedRectangle(cornerRadius: 13))
        .accessibilityIdentifier("home-reminders-slip")
    }
    private var musicRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { musicIdentity; musicControls }
            VStack(alignment: .leading, spacing: 10) { musicIdentity; musicControls.frame(maxWidth: .infinity) }
        }.padding(.horizontal, 6).padding(.vertical, 4).accessibilityIdentifier("home-music")
    }
    private var musicIdentity: some View {
        Button { navigate(.music) } label: {
            HStack(spacing: 12) {
                Group {
                    if let artwork = player.currentArtwork ?? player.artwork(for: player.track) {
                        MusicKit.ArtworkImage(artwork, width: 62, height: 62)
                    } else { Artwork(url: player.track["cover"].string) }
                }
                .frame(width: 62, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
                .task(id: player.track["appleMusicId"].string) { await player.ensureArtwork(for: player.track) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string)
                        .font(.system(.subheadline, design: .serif)).lineLimit(2)
                    if !player.track["artist"].string.isEmpty {
                        Text(player.track["artist"].string).font(.system(.caption, design: .serif))
                            .foregroundStyle(palette.muted).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityLabel("Open Music, " + (player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string))
    }
    private var musicControls: some View {
        HStack(spacing: 0) {
            Button { player.next(-1) } label: { Image(systemName: "backward.end.fill").font(.system(size: 15)).frame(width: 36, height: 44) }
                .accessibilityLabel("Previous song")
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 18))
                    .frame(width: 44, height: 44).background(palette.accent.opacity(0.16), in: Circle())
            }.accessibilityLabel(player.playing ? "Pause" : "Play")
            Button { player.next(1) } label: { Image(systemName: "forward.end.fill").font(.system(size: 15)).frame(width: 36, height: 44) }
                .accessibilityLabel("Next song")
        }.foregroundStyle(palette.muted).disabled(player.tracks.isEmpty)
    }
    private func loadUsage() async {
        guard !refreshingUsage, !store.token.isEmpty else { return }
        refreshingUsage = true; defer { refreshingUsage = false }
        chat.configure(store); await chat.loadUsage()
    }
    private var remainingUsage: Int? { chat.weeklyRemaining }
    private var greeting: String { let h = Calendar.current.component(.hour, from: .now); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening" }
    private var weatherRow: some View {
        Button { navigate(.weather) } label: {
            HStack(spacing: 5) {
                Image(systemName: weather.snapshot?.icon ?? "cloud.sun")
                if let snapshot = weather.snapshot {
                    Text("\(Int(snapshot.temperature.rounded()))° · " + snapshot.condition)
                } else {
                    Text(weather.loading ? "Updating…" : weather.enabled ? "Local weather" : "Enable weather")
                }
            }.font(.system(.caption, design: .serif)).foregroundStyle(palette.muted).fixedSize()
        }.accessibilityLabel("Open Weather")
    }

}

private struct PaperEdge: Shape {
    let seed: Int
    var rounded = false
    func path(in rect: CGRect) -> Path {
        if rounded { return RoundedRectangle(cornerRadius: 15).path(in: rect) }
        var path = Path()
        let inset: CGFloat = 2
        let box = rect.insetBy(dx: inset, dy: inset)
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        for edge in 0..<4 {
            let a = corners[edge], b = corners[(edge + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(length / 4))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let wave = sin(Double(step * 17 + edge * 31 + seed)) * 0.8
                let x = a.x + (b.x - a.x) * t + (edge % 2 == 1 ? wave : 0)
                let y = a.y + (b.y - a.y) * t + (edge % 2 == 0 ? wave : 0)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

struct DesireTide: View {
    let values: [Double?]
    var compact = false
    @AppStorage("vesperPalette") private var paletteName = "blue"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var previous: [Double] = []
    @State private var target: [Double] = []
    @State private var changedAt = Date.timeIntervalSinceReferenceDate
    private var dark: Bool { paletteName == "black" }
    private var labels: [String] { DesireEmotion.fields.map(\.1) }
    private var ink: Color { dark ? Color(red: 0.89, green: 0.94, blue: 0.96) : Color(red: 0.16, green: 0.29, blue: 0.34) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || phase != .active)) { timeline in
            Canvas { context, size in draw(context: context, size: size, time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate) }
        }
        .onAppear { previous = normalized; target = normalized }
        .onChange(of: values) { _, _ in
            let now = Date.timeIntervalSinceReferenceDate
            previous = (0..<8).map { value($0, time: now) }; target = normalized; changedAt = now
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("八种情绪的潮汐")
        .accessibilityValue(labels.enumerated().map { i, label in label + " " + (values.indices.contains(i) ? values[i].map { String(Int($0)) } ?? "待评估" : "待评估") }.joined(separator: "，"))
    }
    private var normalized: [Double] { (0..<8).map { values.indices.contains($0) ? min(100, max(0, values[$0] ?? 0)) : 0 } }
    private func value(_ i: Int, time: Double) -> Double {
        guard previous.count == 8, target.count == 8 else { return normalized[i] }
        let t = reduceMotion ? 1 : min(1, max(0, (time - changedAt) / 1.5))
        return previous[i] + (target[i] - previous[i]) * t * t * (3 - 2 * t)
    }
    private func shore(_ x: CGFloat, size: CGSize, time: Double) -> CGFloat {
        let u = min(7, max(0, Double(x / max(1, size.width)) * 8 - 0.5))
        let index = min(6, Int(u)), t = u - Double(index)
        let smooth = t * t * (3 - 2 * t)
        let v = value(index, time: time) * (1 - smooth) + value(index + 1, time: time) * smooth
        let cycle = time.truncatingRemainder(dividingBy: 9) / 9
        // Incoming water advances slowly, then drains naturally down the beach.
        let runup = reduceMotion ? 0 : sin(.pi * (cycle < 0.65 ? cycle / 0.65 * 0.5 : 0.5 + (cycle - 0.65) / 0.35 * 0.5)) * 13
        return size.height * (0.62 - v * 0.0038) - runup + CGFloat(sin(Double(x) * 0.027) * 2.8)
    }
    private func line(size: CGSize, time: Double, offset: CGFloat = 0) -> Path {
        var p = Path()
        for x in stride(from: CGFloat(0), through: size.width + 2, by: 2) {
            let point = CGPoint(x: min(x, size.width), y: shore(min(x, size.width), size: size, time: time) + offset)
            if x == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p
    }
    private func draw(context: GraphicsContext, size: CGSize, time: Double) {
        let rect = CGRect(origin: .zero, size: size), bottom = size.height
        let sand = dark ? [Color(red: 0.10, green: 0.17, blue: 0.23), Color(red: 0.15, green: 0.22, blue: 0.27)] : [Color(red: 0.95, green: 0.95, blue: 0.91), Color(red: 0.83, green: 0.88, blue: 0.86)]
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: sand), startPoint: .zero, endPoint: CGPoint(x: size.width, y: bottom)))
        for i in 0..<300 {
            let x = CGFloat((i * 137 + 19) % 997) / 997 * size.width, y = CGFloat((i * 211 + 43) % 991) / 991 * bottom
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(dark ? 0.08 : 0.3)))
        }
        var water = line(size: size, time: time)
        water.addLine(to: CGPoint(x: size.width, y: bottom)); water.addLine(to: CGPoint(x: 0, y: bottom)); water.closeSubpath()
        let colors = dark ? [Color(red: 0.21, green: 0.40, blue: 0.46), Color(red: 0.08, green: 0.22, blue: 0.33), Color(red: 0.04, green: 0.10, blue: 0.19)] : [Color(red: 0.66, green: 0.82, blue: 0.81), Color(red: 0.35, green: 0.62, blue: 0.68), Color(red: 0.15, green: 0.37, blue: 0.49)]
        context.fill(water, with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: bottom * 0.25), endPoint: CGPoint(x: 0, y: bottom)))
        var sea = context; sea.clip(to: water)
        for i in 0..<4 {
            let progress = (time / 9 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
            let offset = CGFloat(1 - progress) * bottom * 0.85
            sea.stroke(line(size: size, time: time, offset: offset), with: .color(.white.opacity(0.05 + progress * 0.14)), lineWidth: 1 + progress)
        }
        context.stroke(line(size: size, time: time), with: .color(.white.opacity(dark ? 0.6 : 0.85)), lineWidth: 2)
        if !compact {
            for i in 0..<8 {
                let x = size.width * (CGFloat(i) + 0.5) / 8, y = shore(x, size: size, time: time) - 22
                let number = values.indices.contains(i) ? values[i].map { String(Int(min(100, max(0, $0)))) } ?? "—" : "—"
                context.draw(Text(number).font(.system(size: 17, design: .serif)).foregroundColor(ink), at: CGPoint(x: x, y: y))
                context.draw(Text(labels[i]).font(.system(size: 12, design: .serif)).foregroundColor(.white.opacity(0.9)), at: CGPoint(x: x, y: bottom - 22))
            }
        }
    }
}


/// On newer iOS the system owns the capsule, spacing and collapsed tab-bar placement.
struct NativeMusicAccessory: ViewModifier {
    let visible: Bool
    let openMusic: () -> Void
    var namespace: Namespace.ID? = nil
    static var isSupported: Bool {
        #if compiler(>=6.2.3)
        if #available(iOS 26.1, *) { return true }
        #endif
        return false
    }
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2.3)
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: visible) { SystemMiniMusicPlayer(openMusic: openMusic, namespace: namespace) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else { content }
        #else
        content
        #endif
    }
}
#if compiler(>=6.2.3)
@available(iOS 26.1, *)
private struct SystemMiniMusicPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let openMusic: () -> Void
    var namespace: Namespace.ID?
    var body: some View {
        MiniMusicPlayer(openMusic: openMusic, systemAccessory: true, compact: placement == .inline, namespace: namespace)
    }
}
#endif

struct MiniMusicPlayer: View {
    @EnvironmentObject private var player: MusicPlayer
    @AppStorage("vesperPalette") private var paletteName = "blue"
    let openMusic: () -> Void
    var systemAccessory = false
    var compact = false
    var namespace: Namespace.ID? = nil
    private var palette: VesperPalette { VesperPalette(rawValue: paletteName) ?? .blue }
    var body: some View {
        Group {
            if systemAccessory { controls }
            else {
                controls.vesperGlass(in: Capsule(), interactive: true)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .modifier(MusicPlayerTransition(namespace: namespace, source: true))
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { gesture in
            if gesture.translation.height < -35 && abs(gesture.translation.height) > abs(gesture.translation.width) * 1.5 { openMusic() }
        })
        .task(id: player.track["appleMusicId"].string) { await player.ensureArtwork(for: player.track) }
        .accessibilityIdentifier("mini-music-player")
        .accessibilityAction(named: "Expand player", openMusic)
    }
    private var controls: some View {
        HStack(spacing: 4) {
            Button(action: openMusic) {
                HStack(spacing: 9) {
                    Group {
                        if let artwork = player.currentArtwork ?? player.artwork(for: player.track) {
                            MusicKit.ArtworkImage(artwork, width: compact ? 28 : 32, height: compact ? 28 : 32)
                        } else { Artwork(url: player.track["cover"].string) }
                    }.frame(width: compact ? 28 : 32, height: compact ? 28 : 32).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !compact && !player.track["artist"].string.isEmpty {
                            Text(player.track["artist"].string).font(.system(size: 11)).lineLimit(1)
                                .foregroundStyle(palette.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open Music, " + (player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string))
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel(player.playing ? "Pause" : "Play").disabled(player.tracks.isEmpty)
            if !compact {
                Button { player.next(1) } label: {
                    Image(systemName: "forward.fill").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                }.accessibilityLabel("Next song").disabled(player.tracks.isEmpty)
            }
        }.buttonStyle(.plain).foregroundStyle(palette.ink)
            .padding(.leading, compact ? 10 : 18).padding(.trailing, 10).padding(.vertical, 2)
    }
}

private struct MusicPlayerTransition: ViewModifier {
    var namespace: Namespace.ID?
    let source: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *), let namespace {
            if source { content.matchedTransitionSource(id: "now-playing", in: namespace) }
            else { content.navigationTransition(.zoom(sourceID: "now-playing", in: namespace)) }
        } else { content }
        #else
        content
        #endif
    }
}

struct MusicPlayerSheet: View {
    var namespace: Namespace.ID? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            MusicView().background { Background() }
                .navigationTitle("Music").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("Minimize player")
                } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
            .modifier(MusicPlayerTransition(namespace: namespace, source: false))
    }
}
