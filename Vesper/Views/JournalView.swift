import SwiftUI

/// Diary keys are Beijing calendar dates, independent of the device's timezone.
enum JournalDay {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    static func key(_ date: Date) -> String { label(date, format: "yyyy-MM-dd") }
    static func label(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func date(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: key), self.key(date) == key else { return nil }
        return date
    }
    static func moving(_ date: Date, by days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
    }
    static func rail(around selected: Date, diary: JSONValue, today: Date = .now) -> [String] {
        var keys = Set(diary.object.keys.filter { date($0) != nil })
        for day in -14...14 { keys.insert(key(moving(selected, by: day))) }
        keys.insert(key(today))
        return keys.sorted()
    }
    static func savingVera(_ text: String, for key: String, in diary: JSONValue, updatedAt: String) -> JSONValue {
        var result = diary
        var entry = diary[key]
        entry["user"] = .string(text)
        entry["updatedAt"] = .string(updatedAt)
        result[key] = entry
        return result
    }
}

private enum JournalAuthor: String, CaseIterable, Identifiable {
    case vera = "Vera", rowan = "Rowan"
    var id: String { rawValue }
    var field: String { self == .vera ? "user" : "agent" }
}

struct JournalView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate = Date()
    @State private var author = JournalAuthor.vera
    @State private var forward = true
    @State private var pickingDate = false
    @State private var editing = false
    @State private var editingKey = ""
    @State private var draft = ""
    @State private var saveError = ""

    private var diary: JSONValue { store.document("diary") }
    private var selectedKey: String { JournalDay.key(selectedDate) }
    private var pageID: String { selectedKey + author.field }
    private var entry: String { diary[selectedKey][author.field].string }
    private var paperInk: Color { Color(red: 0.23, green: 0.22, blue: 0.19) }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.28) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                dateNavigation
                authorSelector
                ScrollView {
                    paper(minHeight: max(360, geometry.size.height - 166))
                        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 28)
                        .frame(maxWidth: 780).frame(maxWidth: .infinity)
                }
                .id(pageID)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .opacity))
                .refreshable { await store.refresh() }
                // Observe horizontal swipes while vertical scrolling and text selection remain available.
                .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { gesture in
                    let delta = gesture.translation
                    guard abs(delta.width) > 70, abs(delta.width) > abs(delta.height) * 1.8 else { return }
                    select(JournalDay.moving(selectedDate, by: delta.width < 0 ? 1 : -1))
                })
                .accessibilityAction(named: "Previous day") { select(JournalDay.moving(selectedDate, by: -1)) }
                .accessibilityAction(named: "Next day") { select(JournalDay.moving(selectedDate, by: 1)) }
            }.padding(.top, 6).clipped()
        }
        .transparentNavigationTop()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: beginEditing) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Write Vera's entry")
                    .disabled(store.saving || store.loading)
            }
        }
        .task { if store.documents["diary"] == nil && !store.loading { await store.refresh() } }
        .sheet(isPresented: $pickingDate) {
            NavigationStack {
                DatePicker("Journal date", selection: Binding(get: { selectedDate }, set: { select($0) }), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.calendar, JournalDay.calendar)
                    .environment(\.timeZone, JournalDay.calendar.timeZone)
                    .padding(20)
                    .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pickingDate = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $editing) {
            EditorSheet(title: "Vera · " + editingKey, busy: store.saving, save: save) {
                FormField(label: "Your day", text: $draft, multiline: true)
                if !saveError.isEmpty { Text(saveError).font(.caption).foregroundStyle(.red) }
            }.interactiveDismissDisabled(store.saving)
        }
    }

    private var dateNavigation: some View {
        VStack(spacing: 8) {
            HStack {
                Button { pickingDate = true } label: {
                    HStack(spacing: 6) {
                        Text(JournalDay.label(selectedDate, format: "MMMM yyyy")).font(.system(.subheadline, design: .serif))
                        Image(systemName: "chevron.down").font(.caption2)
                    }.frame(minHeight: 32)
                }.accessibilityLabel("Choose journal date")
                Spacer()
                Button("Today") { select(.now) }.font(.caption).frame(minHeight: 32)
            }.padding(.horizontal, 24)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(JournalDay.rail(around: selectedDate, diary: diary), id: \.self) { key in
                            dateButton(key).id(key)
                        }
                    }.padding(.horizontal, 20)
                }
                .onAppear { proxy.scrollTo(selectedKey, anchor: .center) }
                .onChange(of: selectedKey) { _, key in
                    withAnimation(animation) { proxy.scrollTo(key, anchor: .center) }
                }
            }.frame(height: 54)
        }
    }

    private func dateButton(_ key: String) -> some View {
        let date = JournalDay.date(key) ?? selectedDate
        let selected = key == selectedKey
        let hasEntry = !diary[key]["user"].string.isEmpty || !diary[key]["agent"].string.isEmpty
        return Button { select(date) } label: {
            VStack(spacing: 5) {
                Text(JournalDay.label(date, format: "MMM d"))
                    .font(.system(.subheadline, design: .serif))
                    .padding(.horizontal, 14).frame(minHeight: 38)
                    .background(selected ? Color(red: 0.96, green: 0.94, blue: 0.88) : .clear, in: Capsule())
                    .foregroundStyle(selected ? paperInk : VesperTheme.ink)
                Circle().fill(VesperTheme.ink.opacity(hasEntry ? 0.65 : 0))
                    .frame(width: 3, height: 3).accessibilityHidden(true)
            }
        }.buttonStyle(.plain)
            .accessibilityLabel(JournalDay.label(date, format: "MMMM d, yyyy") + (hasEntry ? ", diary entry available" : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var authorSelector: some View {
        HStack(spacing: 4) {
            ForEach(JournalAuthor.allCases) { item in
                Button {
                    forward = item == .rowan
                    withAnimation(animation) { author = item }
                } label: {
                    Text(item.rawValue).font(.system(.subheadline, design: .serif))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(author == item ? paperInk : VesperTheme.ink)
                        .background(author == item ? Color(red: 0.96, green: 0.94, blue: 0.88) : .clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(author == item ? .isSelected : [])
            }
        }.padding(4).frame(maxWidth: 270)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel("Journal author")
    }

    private func paper(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(JournalDay.label(selectedDate, format: "MMMM d, yyyy"))
                .font(.system(.subheadline, design: .serif)).foregroundStyle(paperInk.opacity(0.68))
            Text(author.rawValue + "’s day").font(.system(.title, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(paperInk.opacity(0.28)).frame(width: 36, height: 0.5).accessibilityHidden(true)
            if store.loading && store.documents["diary"] == nil {
                ProgressView("Loading your diary…").tint(paperInk)
            } else if store.documents["diary"] == nil && !store.connected {
                Text("Connect to Vesper to load your diary.").font(.system(.body, design: .serif))
                Button("Retry") { Task { await store.refresh() } }.font(.subheadline)
            } else {
                Text(entry.isEmpty ? (author == .vera ? "How did today feel?" : "No entry for this day yet.") : entry)
                    .font(.system(.body, design: .serif)).lineSpacing(9)
                    .foregroundStyle(paperInk.opacity(entry.isEmpty ? 0.6 : 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 48)
            HStack {
                Text(author.rawValue).font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(paperInk.opacity(0.72))
                Spacer()
                if author == .vera {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil").font(.body).frame(width: 44, height: 44)
                            .overlay(Circle().stroke(paperInk.opacity(0.28), lineWidth: 0.7))
                    }.buttonStyle(.plain).accessibilityLabel("Write Vera's entry")
                        .disabled(store.saving || store.loading)
                }
            }
        }
        .foregroundStyle(paperInk).tint(paperInk)
        .padding(.horizontal, 28).padding(.vertical, 32)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background { JournalPaper() }
        .accessibilityIdentifier("journal-paper")
    }

    private func select(_ date: Date) {
        let next = JournalDay.calendar.startOfDay(for: date)
        guard JournalDay.key(next) != selectedKey else { return }
        forward = next > selectedDate
        withAnimation(animation) { selectedDate = next }
    }
    private func beginEditing() {
        editingKey = selectedKey
        draft = diary[editingKey]["user"].string
        saveError = ""
        editing = true
    }
    private func save() {
        // Capture the editor's date and draft before the asynchronous read/modify/write.
        let key = editingKey, text = draft
        Task {
            let saved = await store.mutate("diary", reportErrors: false) { current in
                JournalDay.savingVera(text, for: key, in: current, updatedAt: isoNow())
            }
            if saved {
                author = .vera
                editing = false
            } else { saveError = "Could not save your entry. Your draft is still here; please try again." }
        }
    }
}

/// Paper and its shadow are drawn independently from the live, selectable diary text.
private struct JournalPaper: View {
    var body: some View {
        JournalPaperEdge().fill(LinearGradient(colors: [
            Color(red: 0.99, green: 0.97, blue: 0.92), Color(red: 0.96, green: 0.94, blue: 0.87)
        ], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay {
            Canvas { context, size in
                for i in 0..<2400 {
                    let x = CGFloat((i * 73) % 2503) / 2503 * size.width
                    let y = CGFloat((i * 137) % 2521) / 2521 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.7)),
                        with: .color(Color.brown.opacity(0.06)))
                }
            }.clipShape(JournalPaperEdge())
        }
        .overlay {
            Canvas { context, size in
                // A faint branch enters from the upper right, away from the body margin.
                var stem = Path()
                stem.move(to: CGPoint(x: size.width + 12, y: 38))
                stem.addQuadCurve(to: CGPoint(x: size.width * 0.63, y: 225),
                    control: CGPoint(x: size.width * 0.79, y: 110))
                context.stroke(stem, with: .color(.black.opacity(0.035)), lineWidth: 2)
                for i in 0..<7 {
                    let x = size.width * 0.97 - CGFloat(i) * size.width * 0.045
                    let y = 55 + CGFloat(i) * 24
                    var leafContext = context
                    leafContext.translateBy(x: x, y: y)
                    leafContext.rotate(by: .degrees(i % 2 == 0 ? -36 : 42))
                    leafContext.fill(Path(ellipseIn: CGRect(x: -9, y: -24, width: 18, height: 48)),
                        with: .color(.black.opacity(0.045)))
                }
            }.blur(radius: 3).clipShape(JournalPaperEdge())
        }
        .overlay(JournalPaperEdge().stroke(.white.opacity(0.6), lineWidth: 0.7))
        .shadow(color: Color(red: 0.3, green: 0.32, blue: 0.32).opacity(0.16), radius: 12, x: 1, y: 10)
        .shadow(color: .black.opacity(0.07), radius: 2, x: 0, y: 2)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct JournalPaperEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 1))
        let steps = max(2, Int(rect.width / 12))
        for i in 1...steps {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(steps),
                y: rect.minY + CGFloat((i * 7) % 3) * 0.45))
        }
        path.addLine(to: CGPoint(x: rect.maxX - 0.6, y: rect.maxY - 1))
        for i in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(steps),
                y: rect.maxY - CGFloat((i * 11) % 3) * 0.45))
        }
        path.closeSubpath()
        return path
    }
}
