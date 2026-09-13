import SwiftUI
import UserNotifications
import PhotosUI
import UIKit

private struct DatePhotoBackground: View {
    let url: String
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.82)
                if let imageURL = URL(string: url), imageURL.scheme == "https" {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } placeholder: { Color.clear }
                    Color.white.opacity(0.42)
                }
            }
        }.clipped()
    }
}

struct CollectionView: View {
    enum Kind: String { case notes = "Notes", reminders = "Reminders", dates = "Dates"
        var key: String { self == .notes ? "notes" : self == .reminders ? "todos" : "anniversaries" }
    }
    let kind: Kind
    @EnvironmentObject private var store: AppStore
    @State private var editing: JSONValue?
    @State private var pendingDelete: JSONValue?
    var body: some View {
        Group {
        if kind == .dates { DatesBoard() } else {
        Page(title: kind.rawValue) {
            Button { editing = .object(["id": .string(UUID().uuidString), "createdAt": .string(isoNow())]) } label: { Label("Add \(kind == .notes ? "note" : kind == .dates ? "date" : "reminder")", systemImage: "plus") }
            if store.document(kind.key).array.isEmpty { EmptyCard(title: "Your space", message: "Add something you want to keep here.") }
            ForEach(store.document(kind.key).array) { item in
                CollectionCard(paper: kind == .notes) {
                    HStack(alignment: .top, spacing: 12) {
                        if kind == .reminders {
                            Button { Task { var next = item; next["done"] = .bool(!item["done"].bool); _ = await store.upsert(kind.key, item: next) } } label: { Image(systemName: item["done"].bool ? "checkmark.circle.fill" : "circle") }.disabled(store.saving)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item[kind == .notes ? "text" : "title"].string).font(.subheadline).textSelection(.enabled)
                                .strikethrough(kind == .reminders && item["done"].bool)
                            if kind == .dates { Text(dateCaption(item)).font(.title2); Text(item["date"].string).font(.caption).foregroundStyle(VesperTheme.muted) }
                            if kind == .reminders && !item["due"].string.isEmpty { Text(item["due"].string).font(.caption).foregroundStyle(VesperTheme.muted) }
                            if kind == .notes { Text(item["kind"].string == "agent" ? "Rowan" : "Vera").font(.caption).foregroundStyle(VesperTheme.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu { Button("Edit") { editing = item }; Button("Delete", role: .destructive) { pendingDelete = item } } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Item actions")
                    }
                }
            }
        }
        } }.refreshable { await store.refresh() }
        .sheet(item: $editing) { item in CollectionEditor(kind: kind, item: item) }
        .confirmationDialog("Delete this item?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = pendingDelete { Task { _ = await store.remove(kind.key, id: item.id); pendingDelete = nil } } }
        }
    }
    private func dateCaption(_ item: JSONValue) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard var date = f.date(from: item["date"].string) else { return "Choose a date" }
        let c = Calendar.current; let today = c.startOfDay(for: .now)
        if item["repeats"].bool {
            let md = c.dateComponents([.month, .day], from: date)
            date = c.nextDate(after: today.addingTimeInterval(-1), matching: md, matchingPolicy: .nextTime) ?? date
        }
        let days = c.dateComponents([.day], from: today, to: c.startOfDay(for: date)).day ?? 0
        return days == 0 ? "Today" : days > 0 ? "\(days) days to go" : "\(-days) days together"
    }
}
struct CollectionEditor: View {
    let kind: CollectionView.Kind
    let item: JSONValue
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date()
    @State private var repeats = false
    @State private var due = ""
    @State private var validation = ""
    var body: some View {
        EditorSheet(title: kind.rawValue, busy: store.saving, save: save) {
            FormField(label: kind == .notes ? "Note" : "Title", text: $text, multiline: kind == .notes)
            if kind == .dates { DatePicker("Date", selection: $date, displayedComponents: .date); Toggle("Repeat every year", isOn: $repeats) }
            if kind == .reminders { FormField(label: "Due date or time (optional)", text: $due) }
            if !validation.isEmpty { Text(validation).foregroundStyle(.red) }
        }.onAppear {
            text = item[kind == .notes ? "text" : "title"].string; due = item["due"].string; repeats = item["repeats"].bool
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; date = f.date(from: item["date"].string) ?? .now
        }
    }
    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { validation = "Please enter some text."; return }
        var next = item
        next[kind == .notes ? "text" : "title"] = .string(text)
        if kind == .notes { if next["kind"] == .null { next["kind"] = .string("user") }; if next["tone"] == .null { next["tone"] = .string("blue") } }
        if kind == .reminders { next["due"] = .string(due); if next["done"] == .null { next["done"] = .bool(false) }; if next["tag"] == .null { next["tag"] = .string("") } }
        if kind == .dates { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; next["date"] = .string(f.string(from: date)); next["repeats"] = .bool(repeats) }
        Task { if await store.upsert(kind.key, item: next) { dismiss() } else { validation = store.error ?? "Save failed" } }
    }
}

private struct CollectionCard<Content: View>: View {
    var paper: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if paper {
            content.padding(.horizontal, 20).padding(.top, 32).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Rectangle().fill(LinearGradient(colors: [Color(red: 0.98, green: 0.97, blue: 0.91), Color(red: 0.94, green: 0.93, blue: 0.85)], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.30)).frame(height: 22) }
                        .overlay { Canvas { context, size in
                            for i in 0..<180 {
                                let x = CGFloat((i * 53) % 997) / 997 * size.width
                                let y = CGFloat((i * 97) % 991) / 991 * size.height
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.brown.opacity(0.07)))
                            }
                        }.allowsHitTesting(false) }
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 1, y: 5)
                }
        } else { GlassCard { content } }
    }
}

struct JournalView: View {
    @EnvironmentObject private var store: AppStore
    @State private var month = Date()
    @State private var selected: String?
    @State private var activity: JSONValue = .null
    @State private var activityError = false
    @State private var text = ""
    @State private var editing = false
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func dateKey(_ date: Date, format: String = "yyyy-MM-dd") -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = format; return f.string(from: date)
    }
    private var monthKey: String { dateKey(month, format: "yyyy-MM") }
    private var ready: Bool { activity["month"].string == monthKey && !activityError }
    private var firstDay: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month))! }
    private var offset: Int { calendar.component(.weekday, from: firstDay) - 1 }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: month)!.count }
    var body: some View {
        Page(title: "Journal", subtitle: selected ?? "Conversations and moments, day by day.") {
            if let key = selected { dayDetails(key) } else { monthGrid }
            if activityError { Button("Chat statistics unavailable · Retry") { Task { await loadActivity() } }.font(.caption) }
            else if !ready { ProgressView("Loading chat history…") }
        }
        .task(id: monthKey) { await loadActivity() }
        .refreshable { await store.refresh(); await loadActivity() }
        .sheet(isPresented: $editing) {
            EditorSheet(title: selected ?? "Journal", busy: store.saving, save: save) {
                FormField(label: "Your day", text: $text, multiline: true)
            }
        }
    }
    private var monthGrid: some View {
        VStack(spacing: 14) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                Spacer(); Text(dateKey(month, format: "MMMM yyyy")).font(.headline); Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
            }
            GlassCard(padding: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, label in Text(label).font(.caption).foregroundStyle(VesperTheme.muted) }
                    ForEach(0..<(offset + dayCount), id: \.self) { index in
                        if index < offset { Color.clear.frame(height: 48) }
                        else { dayCell(index - offset + 1) }
                    }
                }
            }
            HStack(spacing: 6) { Text("Less"); ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 3).fill(heatColor(level)).frame(width: 16, height: 16) }; Text("More") }.font(.caption)
            Text("Beijing time · Dots mark journal entries. Autonomous notes are counted separately.").font(.caption).foregroundStyle(VesperTheme.muted)
        }
    }
    private func dayCell(_ day: Int) -> some View {
        let key = monthKey + String(format: "-%02d", day)
        let count = Int(activity["days"][key]["total"].number)
        let level = count == 0 ? 0 : count < 10 ? 1 : count < 30 ? 2 : count < 60 ? 3 : 4
        return Button { selected = key } label: {
            VStack(spacing: 2) {
                Text("\(day)").font(.system(size: 14, weight: .medium))
                Text(key > dateKey(.now) ? " " : ready ? "\(count)" : "—").font(.system(size: 8)).monospacedDigit()
                HStack(spacing: 3) {
                    if !store.document("diary")[key]["user"].string.isEmpty { Circle().fill(VesperTheme.ink).frame(width: 3, height: 3) }
                    if !store.document("diary")[key]["agent"].string.isEmpty { Circle().fill(Color.brown).frame(width: 3, height: 3) }
                }.frame(height: 3)
            }.frame(maxWidth: .infinity, minHeight: 48)
                .background(heatColor(ready ? level : 0), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(key == dateKey(.now) ? VesperTheme.ink : .clear, lineWidth: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(key), \(ready ? String(count) : "unknown") chat messages")
    }
    private func dayDetails(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { selected = nil } label: { Label("Back to calendar", systemImage: "chevron.left").frame(minHeight: 44) }
            GlassCard { VStack(alignment: .leading, spacing: 8) {
                Text(ready ? "\(Int(activity["days"][key]["total"].number)) chat messages" : "— chat messages").font(.headline)
                Text(ready ? "Vera \(Int(activity["days"][key]["user"].number)) · Rowan \(Int(activity["days"][key]["agent"].number))" : "Counts unavailable").font(.caption)
                Text(ready ? "Autonomous notes: \(Int(activity["days"][key]["autonomous"].number))" : "Autonomous notes: —").font(.caption)
            } }
            CollectionCard(paper: true) { VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Vera").font(.headline); Spacer(); Button("Write") { text = store.document("diary")[key]["user"].string; editing = true } }
                Text(store.document("diary")[key]["user"].string.isEmpty ? "How did today feel?" : store.document("diary")[key]["user"].string).textSelection(.enabled)
            } }
            CollectionCard(paper: true) { VStack(alignment: .leading, spacing: 12) {
                Text("Rowan").font(.headline)
                Text(store.document("diary")[key]["agent"].string.isEmpty ? "No entry for this day yet." : store.document("diary")[key]["agent"].string).textSelection(.enabled)
            } }
        }
    }
    private func heatColor(_ level: Int) -> Color { VesperTheme.accent.opacity([0.06, 0.22, 0.40, 0.62, 0.85][level]) }
    private func moveMonth(_ amount: Int) { month = calendar.date(byAdding: .month, value: amount, to: firstDay)!; activity = .null }
    private func loadActivity() async {
        let requested = monthKey
        do {
            let result = try await store.api.request("/activity?month=\(requested)", history: true)
            guard result["month"].string == requested, case .object = result["days"] else { throw ServiceError(message: "Invalid activity response") }
            guard requested == monthKey else { return }; activity = result; activityError = false
        } catch { if requested == monthKey { activityError = true } }
    }
    private func save() {
        guard let key = selected else { return }
        Task {
            let saved = await store.mutate("diary") { current in
                var result = current; var entry = current[key]; entry["user"] = .string(text); entry["updatedAt"] = .string(isoNow()); result[key] = entry; return result
            }
            if saved { editing = false }
        }
    }
}

/// Date-only calculations use calendar days, including across daylight-saving changes.
enum DateCounter {
    static func baseDate(_ item: JSONValue) -> Date? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: item["date"].string)
    }
    static func target(_ item: JSONValue, now: Date = .now) -> Date? {
        guard var target = baseDate(item) else { return nil }
        var c = Calendar(identifier: item["calendar"].string == "lunar" ? .chinese : .gregorian)
        c.timeZone = .current
        let today = c.startOfDay(for: now)
        let rule = item["repeatRule"].string.isEmpty ? (item["repeats"].bool ? "yearly" : "none") : item["repeatRule"].string
        if rule != "none", target < today {
            var components: DateComponents
            switch rule {
            case "weekly": components = c.dateComponents([.weekday], from: target)
            case "monthly": components = c.dateComponents([.day], from: target)
            default: components = c.dateComponents([.month, .day], from: target)
            }
            components.hour = 0; components.minute = 0; components.second = 0
            let upcoming = c.nextDate(after: today.addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime) ?? target
            if let end = baseDate(.object(["date": item["endDate"]])), upcoming > c.startOfDay(for: end) {
                target = end
            } else { target = upcoming }
        }
        if item["preciseTime"].bool {
            let parts = item["time"].string.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { target = c.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: target) ?? target }
        }
        return target
    }
    static func days(_ item: JSONValue, now: Date = .now) -> Int? {
        guard let target = target(item, now: now) else { return nil }
        let c = Calendar.current
        return c.dateComponents([.day], from: c.startOfDay(for: now), to: c.startOfDay(for: target)).day
    }
    static func count(_ item: JSONValue, now: Date = .now) -> Int? {
        guard let days = days(item, now: now) else { return nil }
        return abs(days) + (item["includeToday"].bool ? 1 : 0)
    }
    static func relation(_ item: JSONValue) -> String { guard let days = days(item) else { return "" }; return days < 0 ? "已经" : days > 0 ? "还有" : "就在今天" }
    static func color(_ item: JSONValue) -> Color {
        switch item["color"].string {
        case "rose": return Color(red: 0.73, green: 0.48, blue: 0.53)
        case "sage": return Color(red: 0.42, green: 0.61, blue: 0.52)
        case "gold": return Color(red: 0.75, green: 0.58, blue: 0.32)
        default: return (days(item) ?? 0) < 0 ? Color(red: 0.75, green: 0.58, blue: 0.38) : VesperTheme.accent
        }
    }
    static func dateLabel(_ item: JSONValue) -> String {
        guard let date = target(item) else { return "Choose a date" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.calendar = Calendar(identifier: item["calendar"].string == "lunar" ? .chinese : .gregorian)
        f.dateFormat = item["calendar"].string == "lunar" ? "MMM d日" : "yyyy-MM-dd EEEE"
        return (item["calendar"].string == "lunar" ? "农历 " : "") + f.string(from: date) + (item["preciseTime"].bool ? " " + item["time"].string : "")
    }
}

private struct DatesBoard: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: JSONValue?
    @State private var detail: JSONValue?
    @State private var deleting: JSONValue?
    @State private var category = "All"
    private var items: [JSONValue] {
        store.document("anniversaries").array.filter { category == "All" || $0["category"].string == category }
            .sorted {
                if $0["pinned"].bool != $1["pinned"].bool { return $0["pinned"].bool }
                let a = DateCounter.days($0) ?? Int.max; let b = DateCounter.days($1) ?? Int.max
                if (a >= 0) != (b >= 0) { return a >= 0 }
                return abs(a) < abs(b)
            }
    }
    private var categories: [String] { Array(Set(store.document("anniversaries").array.map { $0["category"].string }.filter { !$0.isEmpty })).sorted() }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Picker("Category", selection: $category) { Text("All dates").tag("All"); ForEach(categories, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                    Spacer()
                    Button { editing = .object(["id": .string(UUID().uuidString), "createdAt": .string(isoNow())]) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add date")
                }
                if let first = items.first { hero(first) }
                if items.isEmpty { EmptyCard(title: "Days to remember", message: "Add a day worth counting.") }
                ForEach(items) { item in
                    Button { detail = item } label: { dateRow(item) }.buttonStyle(.plain)
                        .contextMenu { Button("Edit") { editing = item }; Button("Delete", role: .destructive) { deleting = item } }
                }
            }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.refreshable { await store.refresh() }
        .sheet(item: $editing) { DateEditor(item: $0) }
        .sheet(item: $detail) { item in
            NavigationStack {
                ZStack { Background(); VStack(spacing: 24) { hero(item); Text(DateCounter.dateLabel(item)).font(.subheadline); if !item["endDate"].string.isEmpty { Text("结束日：" + item["endDate"].string) }; Spacer() }.padding(24).padding(.top, 24) }
                    .navigationTitle(item["title"].string).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { detail = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("Edit") { detail = nil; editing = item } }
                    }
            }
        }
        .confirmationDialog("Delete this date?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { Task {
                if await store.remove("anniversaries", id: item.id) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["date-" + item.id]); deleting = nil }
            } } }
        }
    }
    private func hero(_ item: JSONValue) -> some View {
        Button { detail = item } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(item["title"].string + DateCounter.relation(item)).font(.headline); Spacer(); if item["pinned"].bool { Image(systemName: "pin.fill") } }
                HStack(alignment: .firstTextBaseline, spacing: 8) { Text(DateCounter.count(item).map(String.init) ?? "—").font(.system(size: 72, weight: .light, design: .rounded)).monospacedDigit(); Text("天").font(.title3) }
                Text("目标日：" + DateCounter.dateLabel(item)).font(.caption).foregroundStyle(VesperTheme.muted)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background { DatePhotoBackground(url: item["backgroundUrl"].string) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 3).fill(DateCounter.color(item)).frame(height: 5).padding(.horizontal, 14) }
        }.buttonStyle(.plain)
    }
    private func dateRow(_ item: JSONValue) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item["title"].string + DateCounter.relation(item)).font(.system(size: 15, weight: item["highlight"].bool ? .bold : .medium)).lineLimit(2)
                if !item["category"].string.isEmpty { Text(item["category"].string).font(.caption2).foregroundStyle(VesperTheme.muted) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Text(DateCounter.count(item).map(String.init) ?? "—").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1).frame(width: 78).frame(maxHeight: .infinity).background(DateCounter.color(item))
            Text("天").font(.subheadline).frame(width: 34).frame(maxHeight: .infinity).background(DateCounter.color(item).opacity(0.85))
        }.foregroundStyle(VesperTheme.ink).frame(height: 60).background(.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 8)).shadow(color: .black.opacity(0.05), radius: 2, y: 2)
    }
}

private struct DateEditor: View {
    let item: JSONValue
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var lunar = false
    @State private var category = "生活"
    @State private var pinned = false
    @State private var repeatRule = "none"
    @State private var reminder = -1
    @State private var endEnabled = false
    @State private var endDate = Date()
    @State private var precise = false
    @State private var time = Date()
    @State private var includeToday = false
    @State private var color = "blue"
    @State private var highlight = false
    @State private var validation = ""
    @State private var saving = false
    @State private var backgroundUrl = ""
    @State private var backgroundPhoto: PhotosPickerItem?
    @State private var backgroundData: Data?
    @State private var loadingBackground = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("事件名称", text: $title)
                    Toggle("农历", isOn: $lunar)
                    DatePicker("目标日", selection: $date, displayedComponents: .date).environment(\.calendar, Calendar(identifier: lunar ? .chinese : .gregorian))
                    TextField("倒数本", text: $category)
                    Toggle("置顶", isOn: $pinned)
                    Picker("重复", selection: $repeatRule) {
                        Text("不重复").tag("none"); Text("每周").tag("weekly"); Text("每月").tag("monthly"); Text("每年").tag("yearly")
                    }
                    Picker("提醒（下次目标日）", selection: $reminder) {
                        Text("不提醒").tag(-1); Text("当天").tag(0); Text("提前一天").tag(1); Text("提前一周").tag(7)
                    }
                }
                Section("背景") {
                    PhotosPicker(selection: $backgroundPhoto, matching: .images) { Label("更换背景", systemImage: "photo") }.disabled(saving || loadingBackground)
                    if loadingBackground { ProgressView("正在读取照片…") }
                    if let backgroundData, let image = UIImage(data: backgroundData) {
                        Image(uiImage: image).resizable().scaledToFill().frame(height: 150).clipped().listRowInsets(EdgeInsets())
                    } else if !backgroundUrl.isEmpty {
                        DatePhotoBackground(url: backgroundUrl).frame(height: 150)
                    }
                    if backgroundData != nil || !backgroundUrl.isEmpty {
                        Button("恢复默认背景") { backgroundData = nil; backgroundUrl = ""; backgroundPhoto = nil }.disabled(saving || loadingBackground)
                    }
                    Text("保存后应用到这个纪念日的封面。").font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Section {
                    DisclosureGroup("进阶设置") {
                        Toggle("结束日", isOn: $endEnabled)
                        if endEnabled { DatePicker("结束日", selection: $endDate, in: date..., displayedComponents: .date) }
                        Toggle("精确时间", isOn: $precise)
                        if precise { DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute) }
                        Toggle("计数包含当天（+1日）", isOn: $includeToday)
                        Picker("颜色", selection: $color) { Text("海蓝").tag("blue"); Text("玫瑰").tag("rose"); Text("鼠尾草").tag("sage"); Text("暖金").tag("gold") }
                        Toggle("高亮", isOn: $highlight)
                    }
                }
                if !validation.isEmpty { Section { Text(validation).foregroundStyle(.red) } }
            }.scrollContentBackground(.hidden).background { Background() }
                .navigationTitle(item["title"].string.isEmpty ? "添加新日子" : "编辑日子").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || store.saving || loadingBackground) }
                }
        }.onAppear(perform: load).interactiveDismissDisabled(saving || loadingBackground)
            .onChange(of: backgroundPhoto) { _, photo in
                guard let photo else { return }
                Task {
                    loadingBackground = true; defer { loadingBackground = false }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw ServiceError(message: "无法读取这张照片。") }
                        let scale = min(1, 1600 / max(image.size.width, image.size.height))
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                        backgroundData = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
                    } catch { validation = error.localizedDescription }
                }
            }
    }
    private func load() {
        backgroundUrl = item["backgroundUrl"].string
        title = item["title"].string; date = DateCounter.baseDate(item) ?? .now; lunar = item["calendar"].string == "lunar"
        category = item["category"].string.isEmpty ? "生活" : item["category"].string; pinned = item["pinned"].bool
        repeatRule = item["repeatRule"].string.isEmpty ? (item["repeats"].bool ? "yearly" : "none") : item["repeatRule"].string
        reminder = item["reminderDays"] == .null ? -1 : Int(item["reminderDays"].number)
        endEnabled = !item["endDate"].string.isEmpty
        endDate = DateCounter.baseDate(.object(["date": item["endDate"]])) ?? date
        precise = item["preciseTime"].bool; includeToday = item["includeToday"].bool; highlight = item["highlight"].bool
        color = item["color"].string.isEmpty ? "blue" : item["color"].string
        let f = DateFormatter(); f.dateFormat = "HH:mm"; time = f.date(from: item["time"].string) ?? .now
    }
    private func save() async {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { validation = "请输入事件名称"; return }
        guard !endEnabled || endDate >= Calendar.current.startOfDay(for: date) else { validation = "结束日不能早于目标日"; return }
        saving = true; defer { saving = false }
        var next = item
        if let backgroundData {
            do {
                let upload = try await store.api.uploadImage(backgroundData, name: "anniversary-background.jpg")
                let url = upload["url"].string
                if url.isEmpty { backgroundUrl = try APIClient.validatedURL(store.baseURL, path: "/api/media/" + upload["key"].string).absoluteString }
                else { backgroundUrl = url }
                self.backgroundData = nil
            } catch { validation = error.localizedDescription; return }
        }
        next["backgroundUrl"] = .string(backgroundUrl)
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        next["title"] = .string(title); next["date"] = .string(f.string(from: date)); next["calendar"] = .string(lunar ? "lunar" : "solar")
        next["category"] = .string(category); next["pinned"] = .bool(pinned); next["repeatRule"] = .string(repeatRule); next["repeats"] = .bool(repeatRule == "yearly")
        next["includeToday"] = .bool(includeToday); next["color"] = .string(color); next["highlight"] = .bool(highlight)
        next["endDate"] = .string(endEnabled ? f.string(from: endDate) : ""); next["preciseTime"] = .bool(precise)
        f.dateFormat = "HH:mm"; next["time"] = .string(f.string(from: time)); next["reminderDays"] = .number(Double(reminder))
        let center = UNUserNotificationCenter.current()
        var request: UNNotificationRequest?
        if reminder >= 0 {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { validation = "通知权限未开启，请允许通知或选择不提醒。"; return }
                guard let target = DateCounter.target(next), let day = Calendar.current.date(byAdding: .day, value: -reminder, to: target) else { validation = "无法计算提醒时间"; return }
                let fire = precise ? day : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
                guard fire > .now else { validation = "提醒时间已过去，请更改日期或关闭提醒。"; return }
                let content = UNMutableNotificationContent(); content.title = title; content.body = reminder == 0 ? "就是今天。" : "还有 \(reminder) 天。"; content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
                request = UNNotificationRequest(identifier: "date-" + item.id, content: content, trigger: trigger)
            } catch { validation = error.localizedDescription; return }
        }
        guard await store.upsert("anniversaries", item: next) else { validation = store.error ?? "Save failed"; return }
        if let request {
            do { try await center.add(request) } catch { validation = "日期已保存，但提醒未安排：" + error.localizedDescription; return }
        } else { center.removePendingNotificationRequests(withIdentifiers: ["date-" + item.id]) }
        dismiss()
    }
}
