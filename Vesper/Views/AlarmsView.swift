import SwiftUI
#if canImport(AlarmKit)
import AlarmKit

@available(iOS 26.0, *)
private struct VesperAlarmMetadata: AlarmMetadata {}
#endif

struct VesperAlarmItem: Codable, Identifiable {
    let id: UUID
    let title: String
    let date: Date?
    let repeatsDaily: Bool
    var weekdays: [Int]? = nil // Calendar weekday: Sunday = 1, Saturday = 7. Nil preserves older saved alarms.
    var enabled: Bool? = nil

    var isEnabled: Bool { enabled ?? true }
    var selectedDays: Set<Int> { Set(weekdays ?? (repeatsDaily ? Array(1...7) : [])) }
    var time: String { date?.formatted(date: .omitted, time: .shortened) ?? "--:--" }
    var repeatDescription: String {
        let days = selectedDays
        if days.isEmpty { return "Never" }
        if days.count == 7 { return "Every day" }
        if days == Set(2...6) { return "Weekdays" }
        if days == Set([1, 7]) { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return (1...7).filter { days.contains($0) }.map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    var detail: String {
        guard let date else { return "Scheduled on this iPhone" }
        return selectedDays.isEmpty ? date.formatted(date: .abbreviated, time: .shortened) : repeatDescription + " · " + time
    }
    var json: JSONValue {
        .object(["id": .string(id.uuidString), "title": .string(title), "when": .string(date.map { ISO8601DateFormatter().string(from: $0) } ?? ""), "daily": .bool(repeatsDaily), "enabled": .bool(isEnabled)])
    }
}

@MainActor final class VesperAlarms: ObservableObject {
    static let shared = VesperAlarms()
    @Published private(set) var items: [VesperAlarmItem] = []
    @Published private(set) var permission = "Unknown"
    @Published var error: String?
    @Published var busy = false

    private let storageKey = "vesper.alarmkit.owned.v1"
    var supported: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
    private var stored: [VesperAlarmItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([VesperAlarmItem].self, from: data)) ?? []
    }
    private func save(_ values: [VesperAlarmItem]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
    func refresh() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: permission = "Allowed"
            case .denied: permission = "Denied in iPhone Settings"
            case .notDetermined: permission = "Not requested"
            @unknown default: permission = "Unknown"
            }
            do {
                let known = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                let active = try AlarmManager.shared.alarms.map { alarm in
                    known[alarm.id] ?? VesperAlarmItem(id: alarm.id, title: "Vesper alarm", date: nil, repeatsDaily: false)
                }
                let activeIDs = Set(active.map(\.id))
                items = (active + stored.filter { !$0.isEnabled && !activeIDs.contains($0.id) })
                    .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                save(items) // Keep disabled alarms; discard one-time alarms the system has completed.
                error = nil
            } catch { self.error = error.localizedDescription }
            return
        }
        #endif
        items = []
        permission = "Requires iOS 26 or newer and an AlarmKit-enabled build"
    }
    func authorize() async {
        busy = true; defer { busy = false }
        do {
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                guard try await AlarmManager.shared.requestAuthorization() == .authorized else {
                    throw ServiceError(message: "Allow alarms for Vesper in iPhone Settings.")
                }
                refresh(); return
            }
            #endif
            throw ServiceError(message: "AlarmKit needs iOS 26 or newer and Xcode 26 or newer.")
        } catch { self.error = error.localizedDescription; refresh() }
    }
    @discardableResult func create(title: String, date: Date, repeatsDaily: Bool) async throws -> VesperAlarmItem {
        try await create(title: title, date: date, weekdays: repeatsDaily ? Set(1...7) : [])
    }
    @discardableResult func create(title: String, date: Date, weekdays: Set<Int>) async throws -> VesperAlarmItem {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ServiceError(message: "Give the alarm a title of 1–80 characters.") }
        guard weekdays.isSubset(of: Set(1...7)) else { throw ServiceError(message: "Choose valid repeat days.") }
        guard !weekdays.isEmpty || date > Date() else { throw ServiceError(message: "Choose a future time for a one-time alarm.") }
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            let state = manager.authorizationState == .notDetermined ? try await manager.requestAuthorization() : manager.authorizationState
            guard state == .authorized else { throw ServiceError(message: "Alarm permission was not granted. Open iPhone Settings to allow Vesper alarms.") }
            let id = UUID()
            let item = VesperAlarmItem(id: id, title: name, date: date, repeatsDaily: weekdays.count == 7, weekdays: weekdays.sorted(), enabled: true)
            try await schedule(item)
            save(stored.filter { $0.id != id } + [item])
            refresh()
            return item
        }
        #endif
        throw ServiceError(message: "AlarmKit needs iOS 26 or newer and Xcode 26 or newer.")
    }
    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func schedule(_ item: VesperAlarmItem) async throws {
        guard let date = item.date else { throw ServiceError(message: "Set a time for this alarm.") }
        let stop = AlarmButton(text: "Dismiss", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: item.title), stopButton: stop)
        let attributes = AlarmAttributes<VesperAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: .blue)
        let days = item.selectedDays
        let schedule: Alarm.Schedule
        if days.isEmpty {
            schedule = .fixed(date)
        } else {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let time = Alarm.Schedule.Relative.Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            let names: [Locale.Weekday] = days.sorted().map { day in
                switch day {
                case 1: .sunday
                case 2: .monday
                case 3: .tuesday
                case 4: .wednesday
                case 5: .thursday
                case 6: .friday
                default: .saturday
                }
            }
            schedule = .relative(.init(time: time, repeats: .weekly(names)))
        }
        let configuration: AlarmManager.AlarmConfiguration<VesperAlarmMetadata> = .alarm(schedule: schedule, attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: item.id, configuration: configuration)
    }
    #endif
    func setEnabled(_ enabled: Bool, for item: VesperAlarmItem) async throws {
        guard items.contains(where: { $0.id == item.id }) else { throw ServiceError(message: "This alarm is no longer available.") }
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            if enabled == item.isEnabled { return }
            var updated = item
            if enabled {
                if item.selectedDays.isEmpty, let date = item.date, date <= Date() {
                    updated = VesperAlarmItem(id: item.id, title: item.title,
                        date: Calendar.current.nextDate(after: Date(), matching: Calendar.current.dateComponents([.hour, .minute], from: date), matchingPolicy: .nextTime),
                        repeatsDaily: false, weekdays: [], enabled: true)
                }
                try await schedule(updated)
            } else if try AlarmManager.shared.alarms.contains(where: { $0.id == item.id }) {
                try AlarmManager.shared.cancel(id: item.id)
            }
            updated.enabled = enabled
            save(stored.filter { $0.id != item.id } + [updated])
            refresh()
            return
        }
        #endif
        throw ServiceError(message: "AlarmKit is not available on this device.")
    }
    func update(_ item: VesperAlarmItem, title: String, date: Date, weekdays: Set<Int>) async throws {
        guard items.contains(where: { $0.id == item.id }) else { throw ServiceError(message: "This alarm is no longer available.") }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ServiceError(message: "Give the alarm a title of 1–80 characters.") }
        guard weekdays.isSubset(of: Set(1...7)) else { throw ServiceError(message: "Choose valid repeat days.") }
        guard !weekdays.isEmpty || date > Date() else { throw ServiceError(message: "Choose a future time for a one-time alarm.") }
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            // Schedule the replacement first so a failure cannot silently erase the old alarm.
            var updated = VesperAlarmItem(id: UUID(), title: name, date: date,
                repeatsDaily: weekdays.count == 7, weekdays: weekdays.sorted(), enabled: item.isEnabled)
            if item.isEnabled { try await schedule(updated) }
            do {
                if try AlarmManager.shared.alarms.contains(where: { $0.id == item.id }) {
                    try AlarmManager.shared.cancel(id: item.id)
                }
            } catch {
                if item.isEnabled { try? AlarmManager.shared.cancel(id: updated.id) }
                throw error
            }
            updated.enabled = item.isEnabled
            save(stored.filter { $0.id != item.id } + [updated])
            refresh()
            return
        }
        #endif
        throw ServiceError(message: "AlarmKit is not available on this device.")
    }
    func cancel(id: UUID) throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard items.contains(where: { $0.id == id }) else {
                throw ServiceError(message: "This alarm is not scheduled by Vesper.")
            }
            if try AlarmManager.shared.alarms.contains(where: { $0.id == id }) { try AlarmManager.shared.cancel(id: id) }
            save(stored.filter { $0.id != id })
            refresh()
            return
        }
        #endif
        throw ServiceError(message: "AlarmKit is not available on this device.")
    }
    var snapshot: JSONValue {
        .object(["supported": .bool(supported), "permission": .string(permission),
                 "alarms": .array(items.map(\.json)), "error": .string(error ?? ""),
                 "note": .string("Only alarms scheduled by Vesper appear here; Apple's Clock alarms cannot be read or changed.")])
    }
}

struct AlarmsView: View {
    @StateObject private var alarms = VesperAlarms.shared
    @State private var editing: VesperAlarmItem?
    @State private var showingEditor = false
    @State private var title = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var repeatDays: Set<Int> = []
    @State private var showingRepeat = false
    private let calendar = Calendar.current

    private func nextAlarmDate(for time: Date) -> Date {
        calendar.nextDate(after: Date(), matching: calendar.dateComponents([.hour, .minute], from: time), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(60)
    }
    private func open(_ item: VesperAlarmItem? = nil) {
        editing = item
        title = item?.title ?? "Alarm"
        date = item?.date ?? Date().addingTimeInterval(3600)
        repeatDays = item?.selectedDays ?? []
        alarms.error = nil
        showingEditor = true
    }
    var body: some View {
        VesperList {
            if alarms.supported && alarms.permission != "Allowed" {
                Section {
                    Button("Allow Vesper alarms") { Task { await alarms.authorize() } }.disabled(alarms.busy)
                    Text(alarms.permission).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = alarms.error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
            Section("Alarms") {
                if alarms.items.isEmpty { Text("No alarms yet. Tap + to add one.").foregroundStyle(.secondary) }
                ForEach(alarms.items) { item in
                    HStack(spacing: 12) {
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.time).font(.system(size: 46, weight: .light, design: .rounded))
                                    .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                                Text(item.title == "Alarm" ? item.repeatDescription : "\(item.title) · \(item.repeatDescription)")
                                    .font(.subheadline).lineLimit(1)
                            }
                            .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Toggle("\(item.title), \(item.time)", isOn: Binding(
                            get: { alarms.items.first(where: { $0.id == item.id })?.isEnabled ?? item.isEnabled },
                            set: { newValue in Task {
                                alarms.busy = true; defer { alarms.busy = false }
                                do { try await alarms.setEnabled(newValue, for: item) }
                                catch { alarms.error = error.localizedDescription }
                            } }
                        ))
                        .labelsHidden().disabled(alarms.busy)
                    }
                    .padding(.vertical, 6)
                    .swipeActions { Button("Delete", role: .destructive) {
                        do { try alarms.cancel(id: item.id) } catch { alarms.error = error.localizedDescription }
                    } }
                }
                .onDelete { offsets in
                    let ids = offsets.map { alarms.items[$0].id }
                    for id in ids {
                        do { try alarms.cancel(id: id) }
                        catch { alarms.error = error.localizedDescription }
                    }
                }
            }
            Section { Text("Vesper manages only the alarms created here. Alarms in Apple's Clock app stay separate.")
                .font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Alarms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton().disabled(alarms.items.isEmpty)
                Button { open() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add alarm").disabled(!alarms.supported)
            }
        }
        .task { alarms.refresh() }
        .refreshable { alarms.refresh() }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                VesperForm {
                    Section {
                        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                    }
                    Section {
                        Button { showingRepeat = true } label: {
                            LabeledContent("Repeat", value: repeatDays.isEmpty ? "Never" :
                                VesperAlarmItem(id: UUID(), title: title, date: date,
                                    repeatsDaily: repeatDays.count == 7, weekdays: repeatDays.sorted()).repeatDescription)
                        }
                        TextField("Label", text: $title)
                    }
                    if let error = alarms.error { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle(editing == nil ? "Add Alarm" : "Edit Alarm")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingEditor = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task {
                            alarms.busy = true; defer { alarms.busy = false }
                            do {
                                let when = nextAlarmDate(for: date)
                                if let editing { try await alarms.update(editing, title: title, date: when, weekdays: repeatDays) }
                                else { _ = try await alarms.create(title: title, date: when, weekdays: repeatDays) }
                                showingEditor = false
                            }
                            catch { alarms.error = error.localizedDescription }
                        } }.disabled(alarms.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationDestination(isPresented: $showingRepeat) {
                    VesperList {
                        ForEach(1...7, id: \.self) { day in
                            Button {
                                if repeatDays.contains(day) { repeatDays.remove(day) }
                                else { repeatDays.insert(day) }
                            } label: {
                                HStack {
                                    Text(calendar.weekdaySymbols[day - 1]).foregroundStyle(.primary)
                                    Spacer()
                                    if repeatDays.contains(day) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    .navigationTitle("Repeat")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingRepeat = false }
                    } }
                }
            }
        }
    }
}
