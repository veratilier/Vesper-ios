import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var desire: JSONValue = .null
    @State private var desireError = false
    @State private var refreshingUsage = false
    let navigate: (Destination) -> Void
    private let fields = ["longing", "tenderness", "playfulness", "intensity", "attachment", "possessiveness"]
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 13)).foregroundStyle(VesperTheme.muted)
                        Text(greeting + ", Vera").font(VesperTheme.title(32)).minimumScaleFactor(0.65).lineLimit(1)
                        Text("A place for today, too.").font(.system(size: 14)).foregroundStyle(VesperTheme.muted)
                    }.padding(.top, 10).padding(.bottom, 4)
                    if !store.connected {
                        Button("Connect Vesper in Settings") { navigate(.settings) }.font(.footnote)
                    }
                    let width = max(240, min(geometry.size.width, 650) - 32)
                    let height: CGFloat = typeSize.isAccessibilitySize ? 300 : max(208, (geometry.size.height - 152) / 2)
                    if typeSize.isAccessibilitySize {
                        desireCard(height: height)
                        usageCard
                        notesCard(height: 150)
                        remindersCard(height: height)
                        musicCard(height: height)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            desireCard(height: height).frame(width: (width - 12) * 0.60)
                            VStack(spacing: 12) { usageCard.frame(height: 80); notesCard(height: height - 92) }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            remindersCard(height: height).frame(width: (width - 12) * 0.37)
                            musicCard(height: height)
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }.refreshable { await store.refresh(); await loadDesire(); await loadUsage() }
        }.buttonStyle(.plain)
        .task { player.updateLibrary(store.document("music").array); await loadDesire() }
        .onChange(of: store.document("music")) { _, tracks in player.updateLibrary(tracks.array) }
        .onChange(of: store.token) { _, _ in Task { await loadDesire() } }
        .onChange(of: phase) { _, value in if value == .active { Task { await loadDesire() } } }
    }
    private func desireCard(height: CGFloat) -> some View {
        Button { navigate(.desire) } label: {
            HomeCard {
                VStack(alignment: .leading, spacing: 0) {
                    cardTitle("Desire")
                    Spacer(minLength: 0)
                    DesireTide(values: fields.map { key in
                        if case .number(let value) = desire[key] { return min(100, max(0, value)) }; return nil
                    }, compact: true).frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 16)).frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    if desire == .null { Text(desireError ? "Unable to refresh" : "Not loaded yet").font(.system(size: 10)).foregroundStyle(VesperTheme.muted) }
                }
            }.frame(height: height)
        }
    }
    private var usageCard: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Usage").font(VesperTheme.title(21)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { Task { await loadUsage() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 28) }.accessibilityLabel("Refresh usage").disabled(refreshingUsage || store.token.isEmpty)
                }
                HStack { Text("Weekly limit"); Spacer(minLength: 2); Text(remainingUsage.map { "\($0)%" } ?? "—") }.font(.system(size: 10))
                if let remaining = remainingUsage { ProgressView(value: Double(remaining), total: 100).tint(VesperTheme.accent) }
                else { Text(chat.loadingUsage ? "Loading…" : (chat.usageError == nil ? "Tap refresh" : "Unable to refresh · Retry")).font(.system(size: 9)).foregroundStyle(VesperTheme.muted) }
            }
        }
    }
    private func notesCard(height: CGFloat) -> some View {
        Button { navigate(.notes) } label: {
            HomeCard {
                VStack(alignment: .leading, spacing: 7) {
                    cardTitle("Notes")
                    Text(store.document("notes").array.first?["text"].string ?? "A little space for your thoughts.")
                        .font(.system(size: 12)).lineSpacing(2).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }.frame(height: height)
        }
    }
    private func remindersCard(height: CGFloat) -> some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 10) {
                Button { navigate(.reminders) } label: { cardTitle("Reminders") }
                let todos = store.document("todos").array.filter { !$0["done"].bool }
                if todos.isEmpty { Text("Something you want to do today? Leave yourself a reminder.").font(.system(size: 12)).lineSpacing(3).foregroundStyle(VesperTheme.muted) }
                ForEach(Array(todos.prefix(2))) { item in
                    Button { Task { var changed = item; changed["done"] = .bool(true); _ = await store.upsert("todos", item: changed) } } label: { Label(item["title"].string, systemImage: "circle").font(.system(size: 12)).lineLimit(3).multilineTextAlignment(.leading).frame(minHeight: 44) }.disabled(store.saving)
                }
                Spacer(minLength: 0)
            }
        }.frame(height: height)
    }
    private func musicCard(height: CGFloat) -> some View {
        HomeCard {
            VStack(spacing: 5) {
                Button { navigate(.music) } label: { cardTitle("Music") }
                Artwork(url: player.track["cover"].string).frame(width: 76, height: 76).clipShape(Circle())
                Text(player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string).font(.system(size: 11)).lineLimit(1)
                Text(player.track["artist"].string).font(.system(size: 10)).foregroundStyle(VesperTheme.muted).lineLimit(1)
                PlaybackControls().font(.system(size: 18)).frame(height: 36)
                Spacer(minLength: 0)
            }
        }.frame(height: height)
    }
    private func loadDesire() async {
        guard !store.token.isEmpty else { desire = .null; return }
        do { let response = try await store.api.request("/api/desire"); desire = response["data"]; desireError = false }
        catch { desireError = true }
    }
    private func loadUsage() async {
        guard !refreshingUsage, !store.token.isEmpty else { return }
        refreshingUsage = true; defer { refreshingUsage = false }
        chat.configure(store); await chat.loadUsage()
    }
    private var remainingUsage: Int? {
        chat.weeklyRemaining
    }
    private var greeting: String { let h = Calendar.current.component(.hour, from: .now); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening" }
    private func cardTitle(_ value: String) -> some View {
        HStack { Text(value).font(VesperTheme.title(23)).minimumScaleFactor(0.6).lineLimit(1); Spacer(minLength: 1); Image(systemName: "chevron.right").font(.system(size: 10)) }
    }
}
private struct HomeCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.91, green: 0.94, blue: 0.97).opacity(0.80), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.90), lineWidth: 1.3))
    }
}
struct DesireTide: View {
    let values: [Double?]
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    private let labels = ["想念", "温柔", "玩心", "浓度", "依恋", "占有"]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || phase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(context: context, size: size, time: time)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("此刻的潮汐")
        .accessibilityValue(labels.enumerated().map { i, label in label + " " + (values.indices.contains(i) ? values[i].map { String(Int($0)) } ?? "未加载" : "未加载") }.joined(separator: "，"))
    }
    private func value(_ i: Int) -> Double { values.indices.contains(i) ? min(100, max(0, values[i] ?? 0)) : 0 }
    private func shore(_ x: CGFloat, size: CGSize, time: Double) -> CGFloat {
        let u = min(5, max(0, Double(x / size.width) * 6 - 0.5))
        let index = min(4, Int(u)), f = u - Double(index)
        let blend = f * f * (3 - 2 * f)
        let v = value(index) * (1 - blend) + value(index + 1) * blend
        let base = size.height * (0.65 - v * 0.0043)
        let ripple = sin(Double(x) * 0.027 + time * 0.65) * 2 + sin(Double(x) * 0.071 - time * 0.43) * 0.8
        return base + CGFloat(ripple)
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
                let y = shore(x, size: size, time: 0) - 22
                var guide = Path(); guide.move(to: CGPoint(x: x, y: y)); guide.addLine(to: CGPoint(x: x, y: y + 19))
                context.stroke(guide, with: .color(VesperTheme.muted.opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(VesperTheme.muted))
                let number = values.indices.contains(i) ? values[i].map { String(Int(min(100, max(0, $0)))) } ?? "—" : "—"
                context.draw(Text(number).font(.system(size: 19, design: .serif)).foregroundColor(VesperTheme.ink), at: CGPoint(x: x, y: y - 17))
                context.draw(Text(labels[i]).font(.system(size: 13, design: .serif)).foregroundColor(VesperTheme.ink), at: CGPoint(x: x, y: size.height - 14))
            }
        }
    }
}
