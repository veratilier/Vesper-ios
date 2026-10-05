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
    func calendarSnapshot() throws -> JSONValue {
        try Self.calendarSnapshot(authorized: EKEventStore.authorizationStatus(for: .event) == .fullAccess, now: Date()) { start, end in
            store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }.map { event in
                    .object(["title": .string(event.title ?? "Event"), "calendar": .string(event.calendar.title),
                             "start": .string(ISO8601DateFormatter().string(from: event.startDate)),
                             "end": .string(ISO8601DateFormatter().string(from: event.endDate)), "allDay": .bool(event.isAllDay)])
                }
        }
    }
    static func calendarSnapshot(authorized: Bool, now: Date, fetch: (Date, Date) -> [JSONValue]) throws -> JSONValue {
        guard authorized else { throw ServiceError(message: "Calendar read access is unavailable. Allow Calendar access in Vesper Settings → Calendar & Reminders.") }
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let events = fetch(start, end)
        return .object(["source": .string("iPhone Calendar"), "readAt": .string(ISO8601DateFormatter().string(from: now)),
                        "from": .string(ISO8601DateFormatter().string(from: start)), "until": .string(ISO8601DateFormatter().string(from: end)),
                        "timeZone": .string(TimeZone.current.identifier), "events": .array(Array(events.prefix(100))), "hasMore": .bool(events.count > 100)])
    }
    struct WriteRequest {
        let kind: String
        let title: String
        let start: Date?
        let end: Date?
        let notes: String
        let requestID: String
    }
    nonisolated static func writeRequest(_ args: JSONValue) throws -> WriteRequest {
        guard case .object(let fields) = args,
              Set(fields.keys).isSubset(of: ["kind", "title", "start", "end", "notes", "requestId"]),
              ["event", "reminder"].contains(args["kind"].string),
              !args["title"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !args["requestId"].string.isEmpty else {
            throw ServiceError(message: "Provide kind (event or reminder), a title and a stable requestId.")
        }
        func date(_ key: String) throws -> Date? {
            if args[key] == .null { return nil }
            let raw = args[key].string
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let value = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw ServiceError(message: "Use an ISO 8601 date/time with timezone for " + key + ".")
            }
            return value
        }
        let start = try date("start"), end = try date("end")
        if args["kind"].string == "event" {
            guard let start, let end, end > start else { throw ServiceError(message: "Events require start and end; end must be after start.") }
        } else if end != nil { throw ServiceError(message: "Reminders use start for the due date, without end.") }
        return WriteRequest(kind: args["kind"].string, title: args["title"].string, start: start, end: end,
                            notes: args["notes"].string, requestID: args["requestId"].string)
    }
    func createFromChat(_ args: JSONValue) async throws -> JSONValue {
        let request = try Self.writeRequest(args)
        let entity: EKEntityType = request.kind == "event" ? .event : .reminder
        if EKEventStore.authorizationStatus(for: entity) == .notDetermined {
            let granted: Bool
            if entity == .event { granted = try await store.requestFullAccessToEvents() }
            else { granted = try await store.requestFullAccessToReminders() }
            guard granted else { throw ServiceError(message: "Access was not granted. Enable it in iPhone Settings → Apps → Vesper.") }
        }
        guard EKEventStore.authorizationStatus(for: entity) == .fullAccess else {
            throw ServiceError(message: "Allow Calendar or Reminders access in Vesper Settings → Permissions → Calendar & Reminders.")
        }
        // A repeated tool request returns the existing receipt rather than creating another item.
        let key = "vesper.planner.write." + request.requestID
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(JSONValue.self, from: data) {
            guard saved["arguments"] == args else { throw ServiceError(message: "This requestId belongs to a different write; use a new ID for a new item.") }
            return saved["receipt"]
        }
        try Task.checkCancellation()
        let item: EKCalendarItem
        if entity == .event {
            guard let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications else { throw ServiceError(message: "Choose a writable default calendar in iPhone Settings.") }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar; event.title = request.title; event.notes = request.notes
            event.startDate = request.start!; event.endDate = request.end!
            try store.save(event, span: .thisEvent, commit: true); item = event
        } else {
            guard let calendar = store.defaultCalendarForNewReminders(), calendar.allowsContentModifications else { throw ServiceError(message: "Choose a writable default Reminders list in iPhone Settings.") }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar; reminder.title = request.title; reminder.notes = request.notes
            if let due = request.start {
                reminder.dueDateComponents = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(reminder, commit: true); item = reminder
        }
        let receipt: JSONValue = .object(["saved": .bool(true), "id": .string(item.calendarItemIdentifier),
            "kind": .string(request.kind), "title": .string(request.title), "calendar": .string(item.calendar.title),
            "start": args["start"], "end": args["end"], "timeZone": .string(TimeZone.current.identifier)])
        let saved: JSONValue = .object(["arguments": args, "receipt": receipt])
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: key) }
        await refresh()
        return receipt
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
    var reminderOnly: Bool? = nil
    @Environment(\.scenePhase) private var phase
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
        PermissionPage(title: reminderOnly == true ? "Reminders" : reminderOnly == false ? "Calendar" : "Calendar & Reminders") {
            if reminderOnly != true { accessPanel(reminders: false) }
            if reminderOnly != false { accessPanel(reminders: true) }
            if let error = planner.error { Text(error).foregroundStyle(.red).font(.footnote) }
            if reminderOnly != true {
                HStack { Text("Next 7 days").font(.headline); Spacer(); Text("\(planner.events.count)").foregroundStyle(VesperTheme.muted) }.padding(.top, 8)
                PermissionPanel {
                    if planner.events.isEmpty { Text("No events available.").foregroundStyle(VesperTheme.muted) }
                    ForEach(Array(planner.events.enumerated()), id: \.element.calendarItemIdentifier) { index, item in
                        if index > 0 { Divider() }
                        Button { selectedEvent = item; editingEvent = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title ?? "Event").font(.system(size: 16, weight: .medium))
                                    Text(item.startDate.formatted()).font(.footnote).foregroundStyle(VesperTheme.muted)
                                    Text(item.calendar.title).font(.caption).foregroundStyle(VesperTheme.muted)
                                }
                                Spacer()
                                Image(systemName: item.calendar.allowsContentModifications ? "chevron.right" : "lock").font(.caption).foregroundStyle(VesperTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(!item.calendar.allowsContentModifications)
                    }
                }
            }
            if reminderOnly != false {
                HStack { Text("Incomplete reminders").font(.headline); Spacer(); Text("\(planner.reminders.count)").foregroundStyle(VesperTheme.muted) }.padding(.top, 8)
                PermissionPanel {
                    if planner.reminders.isEmpty { Text("No reminders available.").foregroundStyle(VesperTheme.muted) }
                    ForEach(Array(planner.reminders.enumerated()), id: \.element.calendarItemIdentifier) { index, item in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Button { Task { await planner.complete(item) } } label: { Image(systemName: "circle").frame(width: 44, height: 44) }
                                .accessibilityLabel("Complete reminder").disabled(!item.calendar.allowsContentModifications)
                            Button { selectedReminder = item; editingReminder = true } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title ?? "Reminder").font(.system(size: 16, weight: .medium))
                                    Text(item.calendar.title).font(.caption).foregroundStyle(VesperTheme.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.disabled(!item.calendar.allowsContentModifications)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .toolbar { Button { reminder = reminderOnly ?? false; adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add event or reminder") }
        .task(id: phase) { if phase == .active { await planner.refresh() } }.refreshable { await planner.refresh() }
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
    private func accessPanel(reminders: Bool) -> some View {
        let entity: EKEntityType = reminders ? .reminder : .event
        let status = EKEventStore.authorizationStatus(for: entity)
        return PermissionPanel {
            HStack {
                Label(reminders ? "Reminders access" : "Calendar access", systemImage: reminders ? "checklist" : "calendar").font(.headline)
                Spacer()
                Text(PermissionLabels.calendar(entity)).font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Text(reminders ? "Rowan can create tasks in your default Apple Reminders list when you ask." : "Rowan can read the next seven days and create events in your default calendar when you ask.")
                .foregroundStyle(VesperTheme.muted)
            if status == .notDetermined || status == .writeOnly {
                Button("Allow access") { Task { await planner.authorize(reminders: reminders) } }.buttonStyle(PermissionActionStyle())
            } else {
                Button("Open iPhone Settings") { PermissionLabels.openSettings() }.buttonStyle(PermissionActionStyle())
            }
            DisclosureGroup("About this access") {
                Text("Requested details and saved-item confirmations become part of your chat. Creation runs on the connected iPhone. Existing items below can be managed manually.")
                    .font(.footnote).foregroundStyle(VesperTheme.muted).padding(.top, 8)
            }.font(.subheadline)
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
