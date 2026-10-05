import SwiftUI
import MusicKit

/// Select genuine shared content for the desktop; placeholder copy never becomes saved data.
enum HomeDesktopContent {
    static func timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func latestRowanNote(_ notes: [JSONValue]) -> JSONValue? {
        notes.enumerated().filter {
            $0.element["kind"].string == "agent" && !$0.element["text"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.max { left, right in
            func date(_ note: JSONValue) -> Date {
                timestamp(note["createdAt"].string) ?? timestamp(note["updatedAt"].string) ?? .distantPast
            }
            let lhs = date(left.element), rhs = date(right.element)
            return lhs == rhs ? left.offset > right.offset : lhs < rhs
        }?.element
    }
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
    @ObservedObject private var weather = WeatherController.shared
    let navigate: (Destination) -> Void
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
                    rowanLetter
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
                    musicRow
                    if !store.connected {
                        Button("Connect Vesper in Settings") { navigate(.settings) }
                            .font(.footnote).foregroundStyle(palette.muted)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh(); await loadUsage(); weather.refresh(force: true) }
        }
        .foregroundStyle(palette.ink)
        .buttonStyle(.plain)
        .task {
            await store.refresh()
            player.updateLibrary(store.document("music").array)
            await loadUsage()
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                weather.refresh()
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
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
    private var latestNote: JSONValue? { HomeDesktopContent.latestRowanNote(store.document("notes").array) }
    private var rowanLetter: some View {
        Button { navigate(.notes) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("from Rowan").font(VesperTheme.title(21)).foregroundStyle(palette.muted)
                    .frame(height: typeSize.isAccessibilitySize ? nil : 24, alignment: .leading)
                Text("哥哥留下的")
                    .font(.system(.subheadline, design: .default).weight(.light))
                    .foregroundStyle(palette.ink.opacity(0.78))
                Text(latestNote?["text"].string ?? "这里留给哥哥下一张小纸条。")
                    .font(.system(.subheadline, design: .default).weight(.light)).lineSpacing(4)
                    .foregroundStyle(palette.ink.opacity(0.78))
                    .lineLimit(typeSize.isAccessibilitySize ? 8 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = latestNote,
                   let date = HomeDesktopContent.timestamp(note["createdAt"].string)
                    ?? HomeDesktopContent.timestamp(note["updatedAt"].string) {
                    Text(date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(.caption2, design: .serif)).italic()
                        .foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vesperGlass(in: PaperEdge(seed: 9))
        }
        .accessibilityHint("Open Notes to read the full letter")
        .accessibilityIdentifier("home-rowan-letter")
    }
    private func desireCard(height: CGFloat) -> some View {
        Button { navigate(.desire) } label: {
            GeometryReader { geometry in
                Image(palette == .black ? "DesireDarkCoast" : "DesireCoast").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [palette == .black ? .black.opacity(0.5) : .white.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 88)
                    }
                    .overlay(alignment: .topLeading) {
                        HStack {
                            Text("Desire").font(VesperTheme.title(23)).minimumScaleFactor(0.6).lineLimit(1)
                            Spacer(minLength: 1)
                            Image(systemName: "chevron.right").font(.system(size: 10))
                        }.foregroundStyle(palette.ink).padding(12)
                    }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.85), lineWidth: 1.3))
        }.accessibilityLabel("Desire").accessibilityIdentifier("home-desire-print")
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
            .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
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
        .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var previous: [Double] = []
    @State private var target: [Double] = []
    @State private var changedAt = Date.timeIntervalSinceReferenceDate
    private let labels = ["想念", "温柔", "玩心", "浓度", "依恋", "占有"]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || phase != .active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(context: context, size: size, time: time)
            }
        }
        .onAppear { previous = normalized; target = normalized }
        .onChange(of: values) { _, _ in
            let now = Date.timeIntervalSinceReferenceDate
            previous = (0..<6).map { value($0, time: now) }; target = normalized; changedAt = now
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("此刻的潮汐")
        .accessibilityValue(labels.enumerated().map { i, label in label + " " + (values.indices.contains(i) ? values[i].map { String(Int($0)) } ?? "未加载" : "未加载") }.joined(separator: "，"))
    }
    private var normalized: [Double] { (0..<6).map { values.indices.contains($0) ? min(100, max(0, values[$0] ?? 0)) : 0 } }
    private func value(_ i: Int, time: Double) -> Double {
        guard previous.count == 6, target.count == 6 else { return normalized[i] }
        let t = reduceMotion ? 1 : min(1, max(0, (time - changedAt) / 1.2))
        let eased = t * t * (3 - 2 * t)
        return previous[i] + (target[i] - previous[i]) * eased
    }
    private func shore(_ x: CGFloat, size: CGSize, time: Double) -> CGFloat {
        let u = min(5, max(0, Double(x / max(1, size.width)) * 6 - 0.5))
        let index = min(4, Int(u)), t = u - Double(index)
        let p0 = value(max(0, index - 1), time: time), p1 = value(index, time: time)
        let p2 = value(index + 1, time: time), p3 = value(min(5, index + 2), time: time)
        let v = min(100, max(0, 0.5 * ((2 * p1) + (-p0 + p2) * t + (2*p0 - 5*p1 + 4*p2 - p3)*t*t + (-p0 + 3*p1 - 3*p2 + p3)*t*t*t)))
        let base = size.height * (0.65 - v * 0.0043)
        let time = reduceMotion ? 0 : time
        let wave = sin(Double(x) * 0.018 + time * 0.48) * 4.5
        let ripple = sin(Double(x) * 0.037 - time * 0.65) * 2 + sin(Double(x) * 0.079 + time * 0.43) * 0.8
        return base + CGFloat(wave + ripple)
    }
    private func line(size: CGSize, time: Double, offset: CGFloat = 0) -> Path {
        var path = Path()
        for x in stride(from: CGFloat(0), through: size.width, by: 2) {
            let point = CGPoint(x: x, y: shore(x, size: size, time: time) + offset)
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.addLine(to: CGPoint(x: size.width, y: shore(size.width, size: size, time: time) + offset))
        return path
    }
    private func draw(context: GraphicsContext, size: CGSize, time: Double) {
        let bottom = size.height - (compact ? 0 : 40)
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(red: 0.96, green: 0.96, blue: 0.94), Color(red: 0.88, green: 0.92, blue: 0.94)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        // Deterministic mineral grains, not per-frame random noise.
        for i in 0..<550 {
            let x = CGFloat((i * 137 + 19) % 997) / 997 * size.width
            let y = CGFloat((i * 211 + 43) % 991) / 991 * size.height
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.45)))
        }
        var water = line(size: size, time: time)
        water.addLine(to: CGPoint(x: size.width, y: bottom)); water.addLine(to: CGPoint(x: 0, y: bottom)); water.closeSubpath()
        context.fill(water, with: .linearGradient(Gradient(colors: [Color(red: 0.72, green: 0.85, blue: 0.88), Color(red: 0.42, green: 0.66, blue: 0.77), Color(red: 0.24, green: 0.45, blue: 0.61)]), startPoint: CGPoint(x: 0, y: size.height * 0.22), endPoint: CGPoint(x: 0, y: bottom)))
        var sea = context; sea.clip(to: water)
        // Fine crossing caustics give the water depth without an opaque image.
        for row in 0..<36 {
            var caustic = Path()
            for column in 0...60 {
                let x = CGFloat(column) / 60 * size.width
                let y = CGFloat(row) / 36 * bottom + CGFloat(sin(Double(column) * 0.42 + Double(row) * 1.7 + time * 0.12) * 4 + cos(Double(column) * 0.19 - Double(row)) * 3)
                if column == 0 { caustic.move(to: CGPoint(x: x, y: y)) } else { caustic.addLine(to: CGPoint(x: x, y: y)) }
            }
            sea.stroke(caustic, with: .color(.white.opacity(0.12)), lineWidth: 0.7)
        }
        for offset in [CGFloat(0), 8, 18] {
            context.stroke(line(size: size, time: time, offset: offset), with: .color(.white.opacity(offset == 0 ? 0.75 : 0.4)), lineWidth: offset == 0 ? 3 : 0.8)
        }
        for i in 0..<360 {
            let x = CGFloat(i) / 359 * size.width
            let d = CGFloat(sin(Double(i) * 4.7) * 3)
            let y = shore(x, size: size, time: time) + d
            sea.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.8, height: 1.2)), with: .color(.white.opacity(0.6)))
        }
        if !compact {
            for i in 0..<6 {
                let x = size.width * (CGFloat(i) + 0.5) / 6
                let y = shore(x, size: size, time: time) - 22
                var guide = Path(); guide.move(to: CGPoint(x: x, y: y)); guide.addLine(to: CGPoint(x: x, y: y + 19))
                context.stroke(guide, with: .color(Color(red: 0.33, green: 0.43, blue: 0.5).opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Color(red: 0.33, green: 0.43, blue: 0.5)))
                let number = values.indices.contains(i) ? values[i].map { String(Int(min(100, max(0, $0)))) } ?? "—" : "—"
                context.draw(Text(number).font(.system(size: 19, design: .serif)).foregroundColor(Color(red: 0.12, green: 0.23, blue: 0.3)), at: CGPoint(x: x, y: y - 17))
                context.draw(Text(labels[i]).font(.system(size: 13, design: .serif)).foregroundColor(Color(red: 0.12, green: 0.23, blue: 0.3)), at: CGPoint(x: x, y: size.height - 14))
            }
        }
    }
}
