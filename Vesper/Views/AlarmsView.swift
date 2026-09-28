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

    var detail: String {
        guard let date else { return "Scheduled on this iPhone" }
        return repeatsDaily ? "Every day · " + date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }
    var json: JSONValue {
        .object(["id": .string(id.uuidString), "title": .string(title), "when": .string(date.map { ISO8601DateFormatter().string(from: $0) } ?? ""), "daily": .bool(repeatsDaily)])
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
                items = try AlarmManager.shared.alarms.map { alarm in
                    known[alarm.id] ?? VesperAlarmItem(id: alarm.id, title: "Vesper alarm", date: nil, repeatsDaily: false)
                }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                save(items) // The system list is authoritative after dismissing or deleting an alarm.
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
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ServiceError(message: "Give the alarm a title of 1–80 characters.") }
        guard repeatsDaily || date > Date() else { throw ServiceError(message: "Choose a future time for a one-time alarm.") }
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            let state = manager.authorizationState == .notDetermined ? try await manager.requestAuthorization() : manager.authorizationState
            guard state == .authorized else { throw ServiceError(message: "Alarm permission was not granted. Open iPhone Settings to allow Vesper alarms.") }
            let id = UUID()
            let stop = AlarmButton(text: "Dismiss", textColor: .white, systemImageName: "stop.circle")
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: name), stopButton: stop)
            let attributes = AlarmAttributes<VesperAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: .blue)
            let schedule: Alarm.Schedule
            if repeatsDaily {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let time = Alarm.Schedule.Relative.Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                schedule = .relative(.init(time: time, repeats: .weekly([.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday])))
            } else { schedule = .fixed(date) }
            let configuration: AlarmManager.AlarmConfiguration<VesperAlarmMetadata> = .alarm(schedule: schedule, attributes: attributes)
            _ = try await manager.schedule(id: id, configuration: configuration)
            let item = VesperAlarmItem(id: id, title: name, date: date, repeatsDaily: repeatsDaily)
            save(stored.filter { $0.id != id } + [item])
            refresh()
            return item
        }
        #endif
        throw ServiceError(message: "AlarmKit needs iOS 26 or newer and Xcode 26 or newer.")
    }
    func cancel(id: UUID) throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard try AlarmManager.shared.alarms.contains(where: { $0.id == id }) else {
                throw ServiceError(message: "This alarm is not scheduled by Vesper.")
            }
            try AlarmManager.shared.cancel(id: id)
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
    @State private var adding = false
    @State private var title = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var daily = false
    var body: some View {
        List {
            Section("AlarmKit") {
                LabeledContent("Access", value: alarms.permission)
                if alarms.supported {
                    Button("Allow Vesper alarms") { Task { await alarms.authorize() } }.disabled(alarms.busy)
                }
                Text("Vesper can schedule its own system alarms. It cannot view alarms from Apple's Clock app. The iPhone asks for permission before the first alarm.").font(.caption)
            }
            if let error = alarms.error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
            Section("Vesper alarms") {
                if alarms.items.isEmpty { Text("No Vesper alarms scheduled.").foregroundStyle(.secondary) }
                ForEach(alarms.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }.swipeActions { Button("Cancel", role: .destructive) { do { try alarms.cancel(id: item.id) } catch { alarms.error = error.localizedDescription } } }
                }
            }
        }
        .navigationTitle("Alarms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add alarm").disabled(!alarms.supported) }
        .task { alarms.refresh() }
        .refreshable { alarms.refresh() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    TextField("Alarm title", text: $title)
                    Toggle("Every day", isOn: $daily)
                    if daily { DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute) }
                    else { DatePicker("When", selection: $date, in: Date()...) }
                    if let error = alarms.error { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle("New alarm")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task {
                            alarms.busy = true; defer { alarms.busy = false }
                            do { _ = try await alarms.create(title: title, date: date, repeatsDaily: daily); title = ""; adding = false }
                            catch { alarms.error = error.localizedDescription }
                        } }.disabled(alarms.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
