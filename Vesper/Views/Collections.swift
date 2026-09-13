import SwiftUI

struct CollectionView: View {
    enum Kind: String { case notes = "Notes", reminders = "Reminders", dates = "Dates"
        var key: String { self == .notes ? "notes" : self == .reminders ? "todos" : "anniversaries" }
    }
    let kind: Kind
    @EnvironmentObject private var store: AppStore
    @State private var editing: JSONValue?
    @State private var pendingDelete: JSONValue?
    var body: some View {
        Page(title: kind.rawValue) {
            Button { editing = .object(["id": .string(UUID().uuidString), "createdAt": .string(isoNow())]) } label: { Label("Add \(kind == .notes ? "note" : kind == .dates ? "date" : "reminder")", systemImage: "plus") }
            if store.document(kind.key).array.isEmpty { EmptyCard(title: "Your space", message: "Add something you want to keep here.") }
            ForEach(store.document(kind.key).array) { item in
                GlassCard {
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
        }.refreshable { await store.refresh() }
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
struct JournalView: View {
    @EnvironmentObject private var store: AppStore
    @State private var date = Date()
    @State private var text = ""
    @State private var editing = false
    var key: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
    var body: some View {
        Page(title: "Journal", subtitle: "One day at a time.") {
            GlassCard { DatePicker("Choose a day", selection: $date, displayedComponents: .date).datePickerStyle(.graphical) }
            GlassCard { VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Vera").font(.headline); Spacer(); Button("Write") { text = store.document("diary")[key]["user"].string; editing = true } }
                Text(store.document("diary")[key]["user"].string.isEmpty ? "How did today feel?" : store.document("diary")[key]["user"].string).textSelection(.enabled)
            }}
            GlassCard { VStack(alignment: .leading, spacing: 12) {
                Text("Rowan").font(.headline)
                Text(store.document("diary")[key]["agent"].string.isEmpty ? "No entry for this day yet." : store.document("diary")[key]["agent"].string).textSelection(.enabled)
            }}
        }.sheet(isPresented: $editing) {
            EditorSheet(title: key, busy: store.saving, save: {
                Task {
                    let saved = await store.mutate("diary") { current in
                        var result = current; var entry = current[key]; entry["user"] = .string(text); entry["updatedAt"] = .string(isoNow()); result[key] = entry; return result
                    }
                    if saved { editing = false }
                }
            }) { FormField(label: "Your day", text: $text, multiline: true) }
        }
    }
}
