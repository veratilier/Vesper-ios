import SwiftUI
import EventKit
import EventKitUI

@MainActor final class SystemPlanner: ObservableObject {
    static let shared = SystemPlanner()
    let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var reminders: [EKReminder] = []
    @Published var error: String?
    @Published var busy = false
    func authorize(reminders: Bool) async {
        do {
            let granted: Bool
            if reminders { granted = try await store.requestFullAccessToReminders() }
            else { granted = try await store.requestFullAccessToEvents() }
            guard granted else { throw ServiceError(message: "Access was not granted. You can change it in iPhone Settings.") }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        busy = true; error = nil
        defer { busy = false }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
            events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
        } else { events = [] }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            reminders = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
        } else { reminders = [] }
    }
    func create(title: String, reminder: Bool, date: Date, end: Date) async -> Bool {
        do {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError(message: "Enter a title.") }
            if reminder {
                guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let calendar = store.defaultCalendarForNewReminders() else { throw ServiceError(message: "Allow Reminders access and choose a default reminder list in iPhone Settings.") }
                let item = EKReminder(eventStore: store); item.title = title; item.calendar = calendar
                item.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                item.addAlarm(EKAlarm(absoluteDate: date)); try store.save(item, commit: true)
            } else {
                guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, let calendar = store.defaultCalendarForNewEvents else { throw ServiceError(message: "Allow Calendar access and choose a default calendar in iPhone Settings.") }
                guard end > date else { throw ServiceError(message: "The end must be after the start.") }
                let item = EKEvent(eventStore: store); item.title = title; item.calendar = calendar; item.startDate = date; item.endDate = end
                try store.save(item, span: .thisEvent, commit: true)
            }
            await refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func complete(_ item: EKReminder) async {
        do { item.isCompleted = true; try store.save(item, commit: true); await refresh() }
        catch { item.isCompleted = false; self.error = error.localizedDescription }
    }
}

struct SystemPlannerView: View {
    @StateObject private var planner = SystemPlanner.shared
    @State private var selectedEvent: EKEvent?
    @State private var selectedReminder: EKReminder?
    @State private var editingEvent = false
    @State private var editingReminder = false
    @State private var adding = false
    @State private var reminder = false
    @State private var title = ""
    @State private var date = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var saving = false
    var body: some View {
        List {
            Section("Permissions") {
                Button("Allow Calendar access") { Task { await planner.authorize(reminders: false) } }
                Button("Allow Reminders access") { Task { await planner.authorize(reminders: true) } }
                Text("These are your iPhone calendars and reminder lists. Entries stay on your device and its configured accounts.").font(.caption)
            }
            if let error = planner.error { Text(error).foregroundStyle(.red).font(.caption) }
            Section("Calendar · next 7 days") {
                ForEach(planner.events, id: \.calendarItemIdentifier) { item in
                    Button { selectedEvent = item; editingEvent = true } label: { VStack(alignment: .leading) { Text(item.title ?? "Event"); Text(item.startDate.formatted()).font(.caption); Text(item.calendar.title).font(.caption).foregroundStyle(.secondary) } }.disabled(!item.calendar.allowsContentModifications)
                }
                if planner.events.isEmpty { Text("No events available.").foregroundStyle(.secondary) }
            }
            Section("Incomplete reminders") {
                ForEach(planner.reminders, id: \.calendarItemIdentifier) { item in
                    HStack { Button { Task { await planner.complete(item) } } label: { Image(systemName: "circle") }.accessibilityLabel("Complete reminder")
                        Button { selectedReminder = item; editingReminder = true } label: { VStack(alignment: .leading) { Text(item.title ?? "Reminder"); Text(item.calendar.title).font(.caption).foregroundStyle(.secondary) } }.disabled(!item.calendar.allowsContentModifications)
                    }
                }
                if planner.reminders.isEmpty { Text("No reminders available.").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Calendar & Reminders").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add event or reminder") }
        .task { await planner.refresh() }.refreshable { await planner.refresh() }
        .sheet(isPresented: $editingEvent, onDismiss: { Task { await planner.refresh() } }) {
            if let selectedEvent { EventEditor(event: selectedEvent, store: planner.store) }
        }
        .sheet(isPresented: $editingReminder, onDismiss: { Task { await planner.refresh() } }) {
            if let selectedReminder { ReminderEditor(item: selectedReminder, planner: planner) }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    Picker("Type", selection: $reminder) { Text("Event").tag(false); Text("Reminder").tag(true) }
                    TextField("Title", text: $title)
                    DatePicker(reminder ? "Due" : "Start", selection: $date)
                    if !reminder { DatePicker("End", selection: $end) }
                    Text("Saves to your default calendar or reminder list.").font(.caption)
                    if let error = planner.error { Text(error).foregroundStyle(.red) }
                }.disabled(saving).navigationTitle("Add")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { saving = true; Task { if await planner.create(title: title, reminder: reminder, date: date, end: end) { title = ""; adding = false }; saving = false } }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }
    }
}

struct EventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store; controller.event = event; controller.editViewDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true)
        }
    }
}

struct ReminderEditor: View {
    let item: EKReminder
    @ObservedObject var planner: SystemPlanner
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var due = Date()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Notes", text: $notes, axis: .vertical)
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate { DatePicker("Due", selection: $due) }
                Text(item.calendar.title).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Edit reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.onAppear {
            title = item.title ?? ""; notes = item.notes ?? ""
            hasDueDate = item.dueDateComponents != nil
            due = item.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date()
        }
    }
    private func save() {
        guard item.calendar.allowsContentModifications else { error = "This reminder list is read-only."; return }
        let oldTitle = item.title; let oldNotes = item.notes; let oldDue = item.dueDateComponents
        item.title = title; item.notes = notes
        item.dueDateComponents = hasDueDate ? Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) : nil
        do { try planner.store.save(item, commit: true); dismiss() }
        catch { item.title = oldTitle; item.notes = oldNotes; item.dueDateComponents = oldDue; self.error = error.localizedDescription }
    }
}
