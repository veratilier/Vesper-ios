import SwiftUI
import UserNotifications
import PhotosUI
import UIKit

private struct DatePhotoBackground: View {
    let url: String
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VesperTheme.surface
                if let imageURL = URL(string: url), imageURL.scheme == "https" {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } placeholder: { Color.clear }
                    (VesperTheme.palette == .black ? Color.black : Color.white).opacity(0.42)
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
        }.foregroundStyle(VesperTheme.ink).frame(height: 60).background(VesperTheme.surface)
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

struct JottingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    @State private var entries: [JSONValue] = []
    @State private var cursor = ""
    @State private var loading = false
    @State private var error = ""
    @State private var adding = false
    var body: some View {
        Page(title: "Sketch", subtitle: "路过的念头，也可以停在这里。") {
            Button { adding = true } label: { Label("写一点", systemImage: "plus") }
            if entries.isEmpty && !loading && error.isEmpty { EmptyCard(title: "还没有 Sketch", message: "零散想法、短文、想象，不必是一篇日记，也不必写给谁。") }
            ForEach(entries) { entry in
                NavigationLink { JottingTextView(entry: entry) } label: {
                    GlassCard { VStack(alignment: .leading, spacing: 12) {
                        if !entry["title"].string.isEmpty { Text(entry["title"].string).font(.headline) }
                        Text(entry["text"].string).font(.system(size: 17, design: .serif)).lineSpacing(5).lineLimit(6)
                        HStack { Text(entry["author"].string); Spacer(); Text(AlbumPresentation.date(entry["createdAt"].string)?.formatted(date: .abbreviated, time: .shortened) ?? "") }.font(.caption).foregroundStyle(VesperTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading) }
                }.buttonStyle(.plain)
            }
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red); Button("重试") { Task { await load(reset: true) } } }
            if !cursor.isEmpty { Button("更早的 Sketch") { Task { await load(reset: false) } }.disabled(loading) }
        }.task { await load(reset: true) }.refreshable { await load(reset: true) }
        .onChange(of: phase) { _, value in if value == .active { Task { await load(reset: true) } } }
        .sheet(isPresented: $adding, onDismiss: { Task { await load(reset: true) } }) { JottingEditor() }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "limit", value: "30")]
            if !reset && !cursor.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: cursor)) }
            let value = try await store.api.request("/api/jottings?" + (query.percentEncodedQuery ?? ""))
            var seen = Set<String>(); entries = ((reset ? [] : entries) + value["jottings"].array).filter { seen.insert($0.id).inserted }
            cursor = value["before"].string; error = ""
        } catch { self.error = error.localizedDescription }
    }
}
struct JottingTextView: View {
    let entry: JSONValue
    var body: some View {
        Page(title: entry["title"].string.isEmpty ? "Sketch" : entry["title"].string) {
            Text(entry["text"].string).font(.system(size: 19, design: .serif)).lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry["author"].string + " · " + (AlbumPresentation.date(entry["createdAt"].string)?.formatted(date: .abbreviated, time: .shortened) ?? "")).font(.caption).foregroundStyle(VesperTheme.muted)
            ShareLink(item: entry["text"].string)
        }
    }
}
struct JottingReceiptView: View {
    let id: String
    @EnvironmentObject private var store: AppStore
    @State private var entry: JSONValue = .null
    @State private var error = ""
    var body: some View {
        Group {
            if entry != .null { JottingTextView(entry: entry) }
            else if !error.isEmpty { Text(error).foregroundStyle(.secondary).padding() }
            else { ProgressView() }
        }.task {
            do { entry = try await store.api.request("/api/jottings?id=" + id)["jotting"] }
            catch { self.error = error.localizedDescription }
        }
    }
}
private struct JottingEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var busy = false
    @State private var error = ""
    @State private var id = UUID().uuidString
    var body: some View {
        EditorSheet(title: "Sketch", busy: busy, save: save) {
            FormField(label: "标题（可留空）", text: $title)
            FormField(label: "写一点", text: $text, multiline: true)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
    }
    private func save() {
        guard !busy else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "先写一点文字吧。"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let value = try await store.api.request("/api/jottings", method: "POST", body: .object(["id": .string(id), "title": .string(title), "text": .string(text)]))
                guard value["jotting"].id == id else { throw ServiceError(message: "保存尚未确认，请重试。") }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
