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
    static func togglingMood(_ mood: JournalMood, for key: String, author: JournalAuthor,
                             in diary: JSONValue, updatedAt: String) -> JSONValue {
        var result = diary
        var entry = diary[key]
        // Change only this author's tags, retaining future tags and all other diary fields.
        var tags = entry["moods"][author.field].array
        if tags.contains(.string(mood.rawValue)) {
            tags.removeAll { $0 == .string(mood.rawValue) }
        } else { tags.append(.string(mood.rawValue)) }
        entry["moods"][author.field] = .array(tags)
        entry["moodUsedAt"][author.field][mood.rawValue] = .string(updatedAt)
        entry["updatedAt"] = .string(updatedAt)
        result[key] = entry
        return result
    }
}

enum JournalMood: String, CaseIterable, Identifiable {
    // Retain the original IDs so previously saved tags remain selected.
    case happy, attached, missing, secure, satisfied, relieved, curious, sweet
    case calm, hopeful, moved, low, hurt, lonely, anxious, uneasy, restless, angry
    case conflicted, embarrassed, guilty, bored, numb, tired
    var id: String { rawValue }
    var label: String {
        switch self {
        case .happy: "开心"
        case .attached: "依恋"
        case .missing: "想念"
        case .secure: "安心"
        case .satisfied: "满足"
        case .relieved: "释然"
        case .curious: "好奇"
        case .sweet: "心动"
        case .calm: "平静"
        case .hopeful: "期待"
        case .moved: "感动"
        case .low: "低落"
        case .hurt: "委屈"
        case .lonely: "孤独"
        case .anxious: "焦虑"
        case .uneasy: "不安"
        case .restless: "烦躁"
        case .angry: "愤怒"
        case .conflicted: "纠结"
        case .embarrassed: "尴尬"
        case .guilty: "愧疚"
        case .bored: "无聊"
        case .numb: "麻木"
        case .tired: "疲惫"
        }
    }
    var color: Color {
        switch self {
        case .happy, .satisfied, .curious: Color(red: 0.79, green: 0.72, blue: 0.50)
        case .sweet, .attached, .moved: Color(red: 0.77, green: 0.60, blue: 0.66)
        case .calm, .secure, .relieved: Color(red: 0.53, green: 0.69, blue: 0.62)
        case .hopeful: Color(red: 0.49, green: 0.68, blue: 0.64)
        case .missing, .lonely, .conflicted: Color(red: 0.70, green: 0.59, blue: 0.71)
        case .tired, .bored, .numb: Color(red: 0.61, green: 0.65, blue: 0.72)
        case .low, .hurt, .guilty: Color(red: 0.52, green: 0.63, blue: 0.74)
        case .restless, .angry, .anxious, .uneasy, .embarrassed: Color(red: 0.76, green: 0.59, blue: 0.55)
        }
    }
    static func recent(in diary: JSONValue, author: JournalAuthor) -> [JournalMood] {
        var used: [String: String] = [:]
        for (key, entry) in diary.object where JournalDay.date(key) != nil {
            for (id, timestamp) in entry["moodUsedAt"][author.field].object {
                used[id] = max(used[id] ?? "", timestamp.string)
            }
            for tag in entry["moods"][author.field].array {
                if entry["moodUsedAt"][author.field][tag.string].string.isEmpty {
                    used[tag.string] = max(used[tag.string] ?? "", entry["updatedAt"].string.isEmpty ? key : entry["updatedAt"].string)
                }
            }
        }
        let known = allCases.filter { used[$0.rawValue] != nil }.sorted {
            if used[$0.rawValue] == used[$1.rawValue] { return $0.rawValue < $1.rawValue }
            return used[$0.rawValue]! > used[$1.rawValue]!
        }
        return Array((known + allCases.filter { used[$0.rawValue] == nil }).prefix(6))
    }
}

enum JournalAuthor: String, CaseIterable, Identifiable {
    case vera = "Vera", rowan = "Rowan"
    var id: String { rawValue }
    var field: String { self == .vera ? "user" : "agent" }
}

struct JournalView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("vesperPalette") private var paletteName = "blue"
    @ScaledMetric(relativeTo: .subheadline) private var controlSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 22
    @State private var selectedDate: Date
    @State private var author: JournalAuthor
    @State private var forward = true
    @State private var pickingDate = false
    @State private var editing = false
    @State private var editingKey = ""
    @State private var draft = ""
    @State private var saveError = ""
    @State private var savingMood = false
    @State private var showingMoods = false
    @State private var moodSaveError = ""
    @State private var showingMoodError = false

    init(date: Date = .now, author: JournalAuthor = .vera) {
        _selectedDate = State(initialValue: date)
        _author = State(initialValue: author)
    }

    private var diary: JSONValue { store.document("diary") }
    private var selectedKey: String { JournalDay.key(selectedDate) }
    private var pageID: String { selectedKey + author.field }
    private var entry: String { diary[selectedKey][author.field].string }
    private var entryDisplay: JournalEntryDisplay { JournalEntryDisplay(entry) }
    private var palette: VesperPalette { VesperPalette(rawValue: paletteName) ?? .blue }
    private var paperInk: Color { palette == .black ? Color(white: 0.88) : Color(red: 0.25, green: 0.29, blue: 0.31) }
    private var selectionFill: Color {
        switch palette {
        case .white: Color(white: 0.97).opacity(0.9)
        case .blue: Color(red: 0.88, green: 0.94, blue: 0.97).opacity(0.9)
        case .black: Color(white: 0.32).opacity(0.85)
        }
    }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.28) }

    var body: some View {
        VStack(spacing: 8) {
            dateNavigation
            ZStack {
                VStack(spacing: 12) {
                    moodSelector
                    paper
                        .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { gesture in
                            let delta = gesture.translation
                            guard abs(delta.width) > 70, abs(delta.width) > abs(delta.height) * 1.8 else { return }
                            select(JournalDay.moving(selectedDate, by: delta.width < 0 ? 1 : -1))
                        })
                }
                .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 12)
                .frame(maxWidth: 780, maxHeight: .infinity).frame(maxWidth: .infinity)
                .id(author.field)
                .transition(reduceMotion ? .identity : .opacity)
            }
            .id(selectedKey)
            .transition(reduceMotion ? .identity : .asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .opacity))
            .accessibilityAction(named: "Previous day") { select(JournalDay.moving(selectedDate, by: -1)) }
            .accessibilityAction(named: "Next day") { select(JournalDay.moving(selectedDate, by: 1)) }
        }.padding(.top, 6).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .transparentNavigationTop().background { Background() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: beginEditing) { Image(systemName: "square.and.pencil").font(.system(size: controlSize + 3, weight: .regular)) }
                    .accessibilityLabel("Write Vera's entry")
                    .disabled(store.saving || (store.loading && !store.hasLocalData))
            }
        }
        .task { if store.documents["diary"] == nil && !store.loading { await store.refresh() } }
        .sheet(isPresented: $pickingDate) {
            NavigationStack {
                DatePicker("Diary date", selection: Binding(get: { selectedDate }, set: { select($0) }), displayedComponents: .date)
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
        .sheet(isPresented: $showingMoods) {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 4) {
                        ForEach(JournalMood.allCases) { mood in moodButton(mood, compact: true) }
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }.background { Background() }
                    .navigationTitle("情绪词库 · " + author.rawValue).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMoods = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingMoodError) {
            NavigationStack {
                Text(moodSaveError).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background { Background() }
                    .navigationTitle("Mood tags").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMoodError = false } } }
            }.presentationDetents([.medium])
        }
    }

    private var dateNavigation: some View {
        VStack(spacing: 2) {
            HStack {
                Button { pickingDate = true } label: {
                    HStack(spacing: 6) {
                        Text(JournalDay.label(selectedDate, format: "MMMM yyyy")).font(.system(size: controlSize + 1, weight: .regular, design: .serif))
                        Image(systemName: "chevron.down").font(.caption2)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Choose diary date")
                Spacer()
                HStack(spacing: 4) {
                    Button("Today") { select(.now) }.font(.system(size: controlSize, weight: .regular)).frame(minWidth: 44, minHeight: 44)
                    Button {
                        withAnimation(animation) { author = author == .vera ? .rowan : .vera }
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: controlSize + 5, weight: .regular))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8))
                                    .padding(2).background(selectionFill, in: Circle()).offset(x: 4, y: 2)
                            }.frame(width: 32, height: 32)
                            .vesperMaterial(.ultraThinMaterial, in: Circle())
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Switch diary author")
                        .accessibilityValue(author.rawValue)
                        .accessibilityHint("Switch to " + (author == .vera ? "Rowan" : "Vera"))
                }
            }.foregroundStyle(palette.ink).padding(.horizontal, 24)
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
            }.frame(height: max(48, controlSize + 30))
        }
    }

    private func dateButton(_ key: String) -> some View {
        let date = JournalDay.date(key) ?? selectedDate
        let selected = key == selectedKey
        let hasEntry = !diary[key]["user"].string.isEmpty || !diary[key]["agent"].string.isEmpty
        return Button { select(date) } label: {
            VStack(spacing: 4) {
                Text(JournalDay.label(date, format: "MMM d"))
                    .font(.system(size: controlSize, weight: .regular, design: .serif))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(selected ? selectionFill : .clear, in: Capsule())
                    .foregroundStyle(palette.ink)
                Circle().fill(palette.ink.opacity(hasEntry ? 0.65 : 0))
                    .frame(width: 3, height: 3).accessibilityHidden(true)
            }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(JournalDay.label(date, format: "MMMM d, yyyy") + (hasEntry ? ", diary entry available" : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var moodSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(author.rawValue + " · 此刻心情").font(.system(size: captionSize, weight: .regular))
                    .tracking(2).foregroundStyle(palette.muted)
                if savingMood { ProgressView().controlSize(.mini).accessibilityLabel("Saving mood") }
                Spacer()
                if !moodSaveError.isEmpty {
                    Button { showingMoodError = true } label: { Image(systemName: "exclamationmark.circle") }
                        .accessibilityLabel("Mood save error details")
                }
                Button("更多") { showingMoods = true }.font(.system(size: captionSize, weight: .regular))
                    .frame(minWidth: 44, minHeight: 32).contentShape(Rectangle())
            }.padding(.horizontal, 12).padding(.top, 4)
            HStack(spacing: 6) {
                ForEach(JournalMood.recent(in: diary, author: author)) { mood in
                    moodButton(mood, compact: true).frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 12)
        }
        .padding(.bottom, 3)
        .vesperMaterial(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.ink.opacity(0.08), lineWidth: 0.6))
        .accessibilityElement(children: .contain).accessibilityLabel(author.rawValue + " mood tags")
    }

    private func moodButton(_ mood: JournalMood, compact: Bool = false) -> some View {
        let selected = diary[selectedKey]["moods"][author.field].array.contains(.string(mood.rawValue))
        return Button { toggleMood(mood) } label: {
            HStack(spacing: 4) {
                if selected && !compact { Image(systemName: "checkmark").font(.system(size: captionSize - 2, weight: .medium)) }
                Text(mood.label).font(.system(size: controlSize - (compact ? 2 : 1), weight: selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? (palette == .black ? Color.black : Color.white) : palette.ink)
            .frame(maxWidth: compact ? .infinity : nil)
            .padding(.horizontal, compact ? 4 : 10).padding(.vertical, 6)
            .background(selected ? palette.ink : mood.color.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(selected ? palette.ink : mood.color.opacity(0.3), lineWidth: selected ? 1.2 : 0.6))
            .frame(minWidth: compact ? 0 : 44, minHeight: 44).contentShape(Rectangle())
        }
        // AppStore queues writes and re-reads the diary before changing it.
        // Unrelated music/state synchronization must not block mood selection.
        .buttonStyle(.plain).disabled(savingMood)
        .accessibilityLabel(mood.label).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Remove this mood" : "Add this mood; multiple moods can be selected")
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(JournalDay.label(selectedDate, format: "MMMM d, yyyy"))
                .font(.system(size: captionSize + 1, weight: .regular, design: .serif)).foregroundStyle(paperInk.opacity(0.68))
            Text(entryDisplay.title ?? (author.rawValue + "’s day")).font(.system(size: titleSize, weight: .regular, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(paperInk.opacity(0.28)).frame(width: 36, height: 0.5).accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.loading && store.documents["diary"] == nil {
                        ProgressView("Loading your diary…").tint(paperInk)
                    } else if store.documents["diary"] == nil && !store.connected {
                        Text("Connect to Vesper to load your diary.").font(.system(size: bodySize, weight: .regular, design: .serif))
                        Button("Retry") { Task { await store.refresh() } }.font(.subheadline)
                    } else {
                        ChatMarkdownText(content: entry.isEmpty ? (author == .vera ? "How did today feel?" : "No entry for this day yet.") : entryDisplay.body)
                            .font(.system(size: bodySize, weight: .regular, design: .serif)).lineSpacing(6)
                            .foregroundStyle(paperInk.opacity(entry.isEmpty ? 0.6 : 1))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            }
            .id(pageID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .refreshable { await store.refresh() }
            .accessibilityIdentifier("journal-entry-body")
            HStack {
                Text(author.rawValue).font(.system(size: captionSize + 1, weight: .regular, design: .serif).italic())
                    .foregroundStyle(paperInk.opacity(0.72))
                Spacer()
                if author == .vera {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil").font(.system(size: controlSize, weight: .regular)).frame(width: 32, height: 32)
                            .overlay(Circle().stroke(paperInk.opacity(0.28), lineWidth: 0.7))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Write Vera's entry")
                        .disabled(store.saving || (store.loading && !store.hasLocalData))
                }
            }.frame(height: 44)
        }
        .foregroundStyle(paperInk).tint(paperInk)
        .padding(.horizontal, 24).padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { JournalPaper(palette: palette) }
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
    private func toggleMood(_ mood: JournalMood) {
        let key = selectedKey, selectedAuthor = author
        moodSaveError = ""
        savingMood = true
        Task {
            defer { savingMood = false }
            let saved = await store.mutate("diary", reportErrors: false) { current in
                JournalDay.togglingMood(mood, for: key, author: selectedAuthor, in: current, updatedAt: isoNow())
            }
            if !saved { moodSaveError = "情绪标签未能保存。请重试，已有的日记内容仍保留。" }
        }
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
    let palette: VesperPalette
    private var colors: [Color] {
        switch palette {
        case .white: [Color(red: 0.985, green: 0.984, blue: 0.975), Color(red: 0.955, green: 0.956, blue: 0.945)]
        case .blue: [Color(red: 0.97, green: 0.985, blue: 0.99), Color(red: 0.91, green: 0.95, blue: 0.97)]
        case .black: [Color(white: 0.18), Color(white: 0.13)]
        }
    }
    var body: some View {
        JournalPaperEdge().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay {
            Canvas { context, size in
                for i in 0..<2400 {
                    let x = CGFloat((i * 73) % 2503) / 2503 * size.width
                    let y = CGFloat((i * 137) % 2521) / 2521 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.7)),
                        with: .color(palette.ink.opacity(0.045)))
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
        .overlay(JournalPaperEdge().stroke(.white.opacity(palette == .black ? 0.14 : 0.6), lineWidth: 0.7))
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

struct JournalEntryDisplay {
    let title: String?
    let body: String
    init(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        let first = lines.first ?? ""
        let prefix = first.prefix { $0 == "#" }
        if (1...6).contains(prefix.count), first.dropFirst(prefix.count).first == " " {
            title = String(first.dropFirst(prefix.count + 1)); body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
        } else { title = nil; body = text }
    }
}
