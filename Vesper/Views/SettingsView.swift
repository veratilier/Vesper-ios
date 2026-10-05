import SwiftUI
import UserNotifications
import AuthenticationServices
import CryptoKit
import Security
import EventKit
import HealthKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Page(title: "Settings", subtitle: "Make Vesper feel like you.") {
            NavigationLink { ConnectionView() } label: { settingsRow("Connection", subtitle: store.connected ? "Connected to your Vesper" : "Pair this device", icon: "network") }
            NavigationLink { UsageView() } label: { settingsRow("Usage & balances", subtitle: "GPT, ElevenLabs and MiniMax", icon: "chart.bar") }
            NavigationLink { DevicePermissionsView() } label: { settingsRow("Permissions", subtitle: "Weather, health, calendar and reminders", icon: "hand.raised") }
            NavigationLink { WakeView() } label: { settingsRow("Autonomous Wake", subtitle: "Permissions and run history", icon: "sparkles") }
            NavigationLink { VoiceSettingsView() } label: { settingsRow("Voice", subtitle: "ElevenLabs and MiniMax for calls", icon: "waveform") }
            NavigationLink { ToolsView() } label: { settingsRow("Tools", subtitle: "Connected MCP services", icon: "link") }
            NavigationLink { DataSettingsView() } label: { settingsRow("Data", subtitle: "Export and privacy", icon: "archivebox") }
        }.buttonStyle(.plain)
    }
    private func settingsRow(_ title: String, subtitle: String, icon: String) -> some View {
        GlassCard { HStack(spacing: 14) { Image(systemName: icon).frame(width: 42, height: 42).background(VesperTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(VesperTheme.muted) }; Spacer(); Image(systemName: "chevron.right").font(.caption) } }
    }
}
// Shared permission layout keeps the navigation title, cards and actions consistent.
struct PermissionPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @AppStorage("vesperPalette") private var palette = "blue"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .font(.system(size: 15)).padding(20).padding(.bottom, 90)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(VesperTheme.ink)
            .background(palette == "black" ? Color(white: 0.06) : Color(red: 0.96, green: 0.96, blue: 0.95))
    }
}
struct PermissionPanel<Content: View>: View {
    var compact = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 15 : 20)
            .background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(VesperTheme.muted.opacity(0.13), lineWidth: 1))
    }
}
struct PermissionActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(VesperTheme.palette == .black ? Color.black : .white)
            .padding(.horizontal, 18).frame(minHeight: 44)
            .background(VesperTheme.ink, in: Capsule()).opacity(configuration.isPressed ? 0.7 : 1)
    }
}
enum PermissionLabels {
    static func calendar(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: return "Allowed"
        case .writeOnly: return "Write only"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        default: return "Check Settings"
        }
    }
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
struct DevicePermissionsView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var weather = WeatherController.shared
    @State private var notifications = "Checking…"
    @State private var calendar = "Checking…"
    @State private var reminders = "Checking…"
    var body: some View {
        PermissionPage(title: "Permissions") {
            Text("Choose what Vesper can access on this iPhone.").font(.subheadline).foregroundStyle(VesperTheme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                card("Location", icon: "location.fill", status: weather.authorized ? "Allowed" : "Not allowed", detail: "Use your location for local weather.") { WeatherPermissionsView() }
                card("Health", icon: "heart.fill", status: HKHealthStore.isHealthDataAvailable() ? "Manage access" : "Unavailable", detail: "Choose which health summaries Rowan may read.") { HealthView() }
                card("Calendar", icon: "calendar", status: calendar, detail: "Read upcoming events and add plans from chat.") { SystemPlannerView(reminderOnly: false) }
                card("Reminders", icon: "checklist", status: reminders, detail: "Let Rowan add tasks to Apple Reminders.") { SystemPlannerView(reminderOnly: true) }
                card("Notifications", icon: "bell.fill", status: notifications, detail: "Receive date and synced letter reminders.") { NotificationSettingsView() }
            }
        }.task(id: phase) {
            guard phase == .active else { return }
            calendar = PermissionLabels.calendar(.event); reminders = PermissionLabels.calendar(.reminder)
            let value = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            switch value {
            case .authorized: notifications = "Allowed"
            case .provisional, .ephemeral: notifications = "Limited"
            case .denied: notifications = "Off"
            default: notifications = "Not requested"
            }
        }
    }
    private func card<Destination: View>(_ title: String, icon: String, status: String, detail: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            PermissionPanel(compact: true) {
                HStack(alignment: .top) {
                    Image(systemName: icon).font(.system(size: 19))
                    Spacer(minLength: 4)
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(VesperTheme.muted).multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(VesperTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VesperTheme.palette == .black ? Color.black : .white)
                    .padding(.horizontal, 16).frame(height: 34).background(VesperTheme.ink, in: Capsule())
            }.frame(minHeight: typeSize.isAccessibilitySize ? 220 : 190)
        }.buttonStyle(.plain)
    }
}
struct ConnectionView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Page(title: "Connection", subtitle: "Use the same device token as your existing Vesper.") {
            GlassCard { VStack(spacing: 16) {
                FormField(label: "API address", text: $store.baseURL)
                FormField(label: "History address", text: $store.historyURL)
                FormField(label: "Chat address", text: $store.socketURL)
                Text("Device token").font(.caption).foregroundStyle(VesperTheme.muted)
                SecureField("Device token", text: $store.token).foregroundStyle(VesperTheme.ink).textContentType(.password).padding(12).background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                Button { Task { await store.connect() } } label: { HStack { if store.loading { ProgressView() }; Text(store.loading ? "Connecting…" : "Save and connect") }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44).background(VesperTheme.ink, in: Capsule()) }.buttonStyle(.plain).disabled(store.loading)
                Text(store.connected ? "Connected" : "Not connected").font(.caption).foregroundStyle(VesperTheme.muted)
                if let error = store.connectionError { Text(error).font(.caption).foregroundStyle(.red) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled() }
        }
    }
}
struct WakeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var runtime: JSONValue = .null
    @State private var enabled = false
    @State private var allowedTools: Set<String> = []
    @State private var allowedMessages: Set<String> = []
    @State private var busy = false
    @State private var status = ""
    private var supported: Bool { runtime["permissionVersion"].number >= 1 }
    private var jobs: [JSONValue] { runtime["jobs"].array.sorted { $0["created"].number > $1["created"].number } }
    private var recovery: JSONValue { runtime["recovery"] }
    private var nextWakeAt: Date? {
        guard case .number(let timestamp) = runtime["nextAt"], timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    var body: some View {
        List {
            Section {
                Toggle("Automatic wake-up", isOn: $enabled).disabled(!supported || busy)
                if runtime != .null { nextWakeRow }
                if runtime["recoveryVersion"].number >= 1 {
                    Button("Check service connection") { Task { await checkService() } }.disabled(busy)
                    ForEach(runtime["toolRecovery"].object.keys.sorted().filter {
                        runtime["toolRecovery"][$0]["retryAt"].number > Date().timeIntervalSince1970
                    }, id: \.self) { name in
                        Text(name + " paused until " + Date(timeIntervalSince1970: runtime["toolRecovery"][name]["retryAt"].number).formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !runtime["uncertainWrites"].array.isEmpty {
                        Text("An external action has an uncertain result. Check the original service before repeating it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink("Sleep time") { WakeSleepView() }
                NavigationLink("Wake prompt") { WakePromptView() }.disabled(!supported)
                NavigationLink("Permissions") { permissionsPage }.disabled(!supported)
                NavigationLink("Workflow") { WakeWorkflowView() }
            }
            if !supported {
                Section { Text("Refresh the service to check permission support. If unavailable, update the VPS wake service.").font(.caption) }
            }
            if !status.isEmpty { Section { Text(status).font(.caption).textSelection(.enabled) } }
        }.scrollContentBackground(.hidden).background { Background() }
            .navigationTitle("Autonomous Wake").navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(busy).accessibilityLabel("Refresh wake service")
            } }
            .safeAreaInset(edge: .bottom) { saveBar }
            .task {
                if runtime == .null { await load() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard !busy else { continue }
                    // Refresh scheduler data without overwriting unsaved permission switches.
                    if let value = try? await store.api.request("/wake", history: true), !busy { runtime = value }
                }
            }.refreshable { await load() }
    }
    private var saveBar: some View {
        WakeSaveButton(title: busy ? "Saving…" : "Save changes", disabled: !supported || busy) {
            Task { await save() }
        }
    }
    private var nextWakeRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            HStack(alignment: .center, spacing: 12) {
                Text("Next wake")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if !runtime["config"]["enabled"].bool {
                        Text("Paused")
                    } else if recovery["paused"].bool {
                        Text(recovery["reason"].string == "quota" ? "Waiting for account quota" :
                             recovery["reason"].string == "authentication" ? "Login required" : "Paused after repeated failures")
                        if recovery["failureCount"].number > 0 {
                            Text("\(Int(recovery["failureCount"].number)) consecutive failures").font(.caption)
                        }
                        if recovery["retryAt"].number > 0 {
                            Text("Check again: " + Date(timeIntervalSince1970: recovery["retryAt"].number).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                        }
                    } else if let nextWakeAt {
                        if nextWakeAt > timeline.date {
                            Text(nextWakeAt, style: .relative)
                        } else {
                            Text("Waiting for scheduler")
                        }
                        Text(nextWakeAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    } else {
                        Text("No wake scheduled")
                    }
                }.foregroundStyle(VesperTheme.muted)
            }.accessibilityElement(children: .combine)
        }
    }
    private var permissionsPage: some View {
        List {
            NavigationLink {
                permissionPage(messages: true)
            } label: {
                HStack { Text("Message types"); Spacer(); Text("\(allowedMessages.count) enabled").foregroundStyle(VesperTheme.muted) }
            }
            NavigationLink {
                permissionPage(messages: false)
            } label: {
                HStack { Text("Allowed tools"); Spacer(); Text("\(allowedTools.count) enabled").foregroundStyle(VesperTheme.muted) }
            }
        }.disabled(busy).scrollContentBackground(.hidden).background { Background() }
            .navigationTitle("Permissions").navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
            .safeAreaInset(edge: .bottom) { saveBar }
    }
    private var activityPage: some View {
        List {
            if jobs.isEmpty { Text("No activity to show").foregroundStyle(VesperTheme.muted) }
            ForEach(jobs) { job in
                NavigationLink { WakeRunDetail(job: job) } label: { runRow(job) }
            }
        }.scrollContentBackground(.hidden).background { Background() }
            .navigationTitle("Recent activity").navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
    }
    private func permissionPage(messages: Bool) -> some View {
        List {
            Section {
                ForEach(runtime[messages ? "messageOptions" : "toolOptions"].array.map { $0.string }, id: \.self) { name in
                    Toggle(name.replacingOccurrences(of: "_", with: " ").capitalized, isOn: permission(name, messages: messages))
                }
            } footer: {
                Text(messages ? "Choose the kinds of messages Rowan may send." : "External MCP access stays read-only. Tool access does not authorize purchases, deletion or account changes.")
            }
        }.disabled(busy).scrollContentBackground(.hidden).background { Background() }
            .navigationTitle(messages ? "Message types" : "Allowed tools").navigationBarTitleDisplayMode(.inline)
            .transparentNavigationTop()
            .safeAreaInset(edge: .bottom) { saveBar }
    }
    private func runRow(_ job: JSONValue) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(job["status"].string.capitalized).font(.subheadline.weight(.medium))
                Text(Date(timeIntervalSince1970: job["created"].number).formatted()).font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Spacer()
            Text("\(job["calls"].array.count) steps").font(.caption).foregroundStyle(VesperTheme.muted)
        }.padding(.vertical, 3)
    }
    private func permission(_ name: String, messages: Bool) -> Binding<Bool> {
        Binding(get: { (messages ? allowedMessages : allowedTools).contains(name) }, set: { value in
            if messages { if value { allowedMessages.insert(name) } else { allowedMessages.remove(name) } }
            else { if value { allowedTools.insert(name) } else { allowedTools.remove(name) } }
        })
    }
    private func apply(_ value: JSONValue) {
        runtime = value; enabled = value["config"]["enabled"].bool
        allowedTools = Set(value["permissions"]["tools"].array.map { $0.string })
        allowedMessages = Set(value["permissions"]["messages"].array.map { $0.string })
    }
    private func checkService() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            runtime = try await store.api.request("/wake", method: "POST", body: .object(["action": .string("check")]), history: true)
            status = "Connection check queued. This check does not generate a reply or repeat failed actions."
        } catch { status = error.localizedDescription }
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { apply(try await store.api.request("/wake", history: true)); status = "" }
        catch { status = error.localizedDescription }
    }
    private func save() async {
        guard supported, !busy else { return }; busy = true; defer { busy = false }
        let interval = runtime["config"]["intervalMinutes"]
        let permissions: JSONValue = .object(["tools": .array(allowedTools.sorted().map { .string($0) }), "messages": .array(allowedMessages.sorted().map { .string($0) })])
        let body: JSONValue = .object(["action": .string("configure"), "enabled": .bool(enabled), "intervalMinutes": interval, "permissions": permissions])
        do {
            let result = try await store.api.request("/wake", method: "POST", body: body, history: true)
            guard result["permissionVersion"].number >= 1, result["permissions"] == permissions,
                  result["config"]["enabled"].bool == enabled,
                  result["config"]["intervalMinutes"] == interval else {
                throw ServiceError(message: "The server did not confirm these permissions.")
            }
            apply(result); status = "Saved. New permissions are checked before each tool call and message."
        } catch { status = error.localizedDescription }
    }
}
struct WakeSleepView: View {
    @EnvironmentObject private var store: AppStore
    @State private var enabled = true
    @State private var dreamEnabled = true
    @State private var start = Self.date("00:00")
    @State private var end = Self.date("07:00")
    @State private var busy = false
    @State private var supported = false
    @State private var status = ""
    private static let zone = TimeZone(identifier: "Asia/Shanghai")!
    private static func date(_ value: String) -> Date {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: parts.first ?? 0, minute: parts.last ?? 0))!
    }
    private static func time(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
    var body: some View {
        Form {
            if busy { ProgressView("Loading sleep settings…") }
            Section {
                Toggle("Sleep time", isOn: $enabled)
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute)
                Toggle("Save a simulated dream after sleep", isOn: $dreamEnabled)
            } footer: {
                Text("Beijing time. Automatic activity and notifications stay silent during sleep. After sleep, one simulated dream is saved to Memory → 梦. Dreams are imagination, not factual memories.")
            }.disabled(!supported || busy)
            if !status.isEmpty { Section { Text(status).font(.caption).textSelection(.enabled) } }
        }.environment(\.timeZone, Self.zone)
            .navigationTitle("Sleep time").navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(busy).accessibilityLabel("Reload sleep settings")
            } }
            .safeAreaInset(edge: .bottom) {
                WakeSaveButton(title: busy ? "Saving…" : "Save sleep time", disabled: !supported || busy) { Task { await save() } }
            }.task { await load() }.refreshable { await load() }
    }
    private func load() async {
        guard !busy else { return }
        busy = true; status = ""; defer { busy = false }
        do {
            let value = try await store.api.request("/wake", history: true)
            supported = value["sleepVersion"].number >= 1
            guard supported else {
                status = "This history service does not support sleep settings yet. Update it, then tap Reload."
                return
            }
            let setting = value["config"]["sleep"]
            enabled = setting["enabled"].bool; dreamEnabled = setting["dreamEnabled"].bool
            start = Self.date(setting["start"].string); end = Self.date(setting["end"].string)
        } catch {
            if !Task.isCancelled { status = error.localizedDescription + " Tap Reload to try again." }
        }
    }
    private func save() async {
        guard !busy, supported else { return }
        guard Self.time(start) != Self.time(end) else { status = "Choose different start and end times."; return }
        busy = true; defer { busy = false }
        let setting: JSONValue = .object(["enabled": .bool(enabled), "dreamEnabled": .bool(dreamEnabled),
            "start": .string(Self.time(start)), "end": .string(Self.time(end)), "timeZone": .string(Self.zone.identifier)])
        do {
            // Preserve the latest main switch/interval, including changes from another device.
            let latest = try await store.api.request("/wake", history: true)
            let body: JSONValue = .object(["action": .string("configure"), "enabled": latest["config"]["enabled"],
                "intervalMinutes": latest["config"]["intervalMinutes"], "sleep": setting])
            let saved = try await store.api.request("/wake", method: "POST", body: body, history: true)
            let reread = try await store.api.request("/wake", history: true)
            guard saved["config"]["sleep"] == setting, reread["config"]["sleep"] == setting else {
                throw ServiceError(message: "The service did not retain the sleep settings.")
            }
            status = "Saved and verified. Applies to the existing VPS scheduler."
        } catch { status = error.localizedDescription }
    }
}

private struct WakePromptView: View {
    @EnvironmentObject private var store: AppStore
    @State private var prompt = ""
    @State private var currentRules = ""
    @State private var limit = 8000
    @State private var supported = false
    @State private var busy = false
    @State private var status = ""
    var body: some View {
        List {
            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 220)
                    .accessibilityLabel("Additional wake instructions")
                Text("\(prompt.count) / \(limit) characters")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            } header: {
                Text("Your additional instructions")
            } footer: {
                Text("Saved to the VPS. These preferences are added to the current wake rules; they cannot change the interval or permissions. Clear the text and save to use only the current rules.")
            }
            Section {
                DisclosureGroup("Current wake rules from VPS") {
                    Text(currentRules).font(.subheadline).textSelection(.enabled)
                }
            }
            if !status.isEmpty { Section { Text(status).font(.caption).textSelection(.enabled) } }
        }.scrollContentBackground(.hidden).background { Background() }
            .navigationTitle("Wake prompt").navigationBarTitleDisplayMode(.inline).transparentNavigationTop()
            .safeAreaInset(edge: .bottom) {
                WakeSaveButton(title: busy ? "Saving…" : "Save prompt", disabled: !supported || busy || prompt.count > limit) {
                    Task { await save() }
                }
            }
            .task { await load() }
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let value = try await store.api.request("/wake", history: true)
            supported = value["promptMode"].string == "append"
            currentRules = value["defaultPrompt"].string
            limit = max(1, Int(value["promptMaxLength"].number))
            prompt = value["promptAddendum"].string
            status = supported ? "" : "Update the VPS wake service to edit the prompt."
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard supported, !busy, prompt.count <= limit else { return }
        busy = true; defer { busy = false }
        let requested = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await store.api.request("/wake", method: "POST", body: .object(["action": .string("prompt"), "prompt": .string(requested)]), history: true)
            guard result["promptMode"].string == "append", result["promptAddendum"].string == requested else {
                throw ServiceError(message: "The VPS did not confirm the prompt change.")
            }
            currentRules = result["defaultPrompt"].string
            prompt = requested
            status = "Saved on the VPS. The next wake will use these instructions."
        } catch { status = error.localizedDescription }
    }
}
private struct WakeSaveButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VesperTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}
enum WakeWorkflowPresentation {
    static func status(_ value: String) -> String {
        ["running": "进行中", "queued": "等待开始", "saved": "发送中", "success": "完成", "completed": "完成", "partial_failure": "部分未完成", "failure": "失败", "failed": "失败", "interrupted": "已中止", "cancelled": "已取消", "silent": "保持安静", "request_accepted": "请求已受理", "unknown": "尚未确认", "pending": "等待处理"][value] ?? value
    }
    static func time(_ value: Double) -> String {
        value > 0 ? Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened) : ""
    }
}

struct WakeWorkflowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    @State private var jobs: [JSONValue] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        Page(title: "Workflow", subtitle: "Rowan 醒来后实际做过的事") {
            if jobs.isEmpty && !loading && error.isEmpty { EmptyCard(title: "暂时没有记录", message: "下一次醒来后，真实活动和静默原因会留在这里。") }
            ForEach(jobs) { job in
                NavigationLink { WakeRunDetail(job: job) } label: {
                    GlassCard { VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(job["title"].string.isEmpty ? "自唤醒" : job["title"].string).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                        Text(job["summary"].string).font(.subheadline).lineLimit(3)
                        HStack { Text(WakeWorkflowPresentation.time(job["created"].number)); Spacer(); Text(WakeWorkflowPresentation.status(job["outcome"].string.isEmpty ? job["status"].string : job["outcome"].string)) }.font(.caption).foregroundStyle(VesperTheme.muted)
                    } }
                }.buttonStyle(.plain)
            }
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption); Button("重试") { Task { await load(reset: true) } } }
            if nextOffset != nil { Button("更早的记录") { Task { await load(reset: false) } }.disabled(loading) }
        }.task { await load(reset: true) }.refreshable { await load(reset: true) }
        .onChange(of: phase) { _, value in if value == .active { Task { await load(reset: true) } } }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let value = try await store.api.request("/wake?view=workflow&limit=20&offset=\(reset ? 0 : nextOffset ?? 0)", history: true)
            var seen = Set<String>()
            jobs = ((reset ? [] : jobs) + value["jobs"].array).filter { seen.insert($0.id).inserted }
            if case .number(let number) = value["nextOffset"] { nextOffset = Int(number) } else { nextOffset = nil }
            error = ""
        } catch { self.error = error.localizedDescription }
    }
}

struct WakeRunDetail: View {
    let job: JSONValue
    @EnvironmentObject private var store: AppStore
    @State private var updated: JSONValue = .null
    private var record: JSONValue { updated == .null ? job : updated }
    var body: some View {
        Page(title: "Workflow", subtitle: record["title"].string) {
            GlassCard { VStack(alignment: .leading, spacing: 10) {
                Text(WakeWorkflowPresentation.status(record["outcome"].string)).font(.headline)
                Text(WakeWorkflowPresentation.time(record["created"].number)).font(.caption).foregroundStyle(VesperTheme.muted)
                if record["finished"].number > 0 { Text("结束于 " + WakeWorkflowPresentation.time(record["finished"].number)).font(.caption).foregroundStyle(VesperTheme.muted) }
                Text(record["summary"].string).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(Array(record["calls"].array.enumerated()), id: \.offset) { index, call in
                GlassCard { VStack(alignment: .leading, spacing: 8) {
                    Text("\(index + 1). " + (call["action"].string.isEmpty ? call["name"].string : call["action"].string)).font(.headline)
                    Text(WakeWorkflowPresentation.status(call["completion"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                    Text(call["result"].string).font(.subheadline).textSelection(.enabled)
                    if call["started"].number > 0 { Text(WakeWorkflowPresentation.time(call["started"].number)).font(.caption).foregroundStyle(VesperTheme.muted) }
                    ForEach(call["references"].array) { reference in
                        if reference["kind"].string == "jottings" { NavigationLink("查看 Sketch") { JottingReceiptView(id: reference.id) } }
                        if reference["kind"].string == "bookmarks" { NavigationLink("查看书签") { BookmarksView() } }
                    }
                    DisclosureGroup("技术详情") { Text(call["name"].string).font(.caption).textSelection(.enabled); Text(call["status"].string).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading) }
            }
            GlassCard { VStack(alignment: .leading, spacing: 10) {
                Text(record["notification"].string.isEmpty ? "保持安静" : "发给 Vera 的消息").font(.headline)
                Text(record["notification"].string.isEmpty ? record["silentReason"].string : record["notification"].string).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            DisclosureGroup("运行详情") { Text("\(Int(record["tokens"].number)) tokens").font(.caption); Text(record.id).font(.caption).textSelection(.enabled) }
        }.task {
            var components = URLComponents()
            components.path = "/wake"
            components.queryItems = [URLQueryItem(name: "view", value: "workflow"), URLQueryItem(name: "id", value: job.id)]
            guard let path = components.string else { return }
            repeat {
                if let value = try? await store.api.request(path, history: true) { updated = value["job"] }
                guard ["running", "queued", "saved"].contains(record["status"].string) else { return }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

struct AgentSettingsView: View {
    @AppStorage("nativeInstructions") private var instructions = "You are Rowan, Vera’s familiar companion. Speak naturally in Chinese. Use Vesper’s built-in tools for its data."
    var body: some View {
        Page(title: "Agent") {
            GlassCard { VStack(alignment: .leading, spacing: 12) { FormField(label: "Instructions for new conversations", text: $instructions, multiline: true); Text("Saved on this device. Existing conversations retain their instructions.").font(.caption).foregroundStyle(VesperTheme.muted) } }
            EmptyCard(title: "Models", message: "Choose an available model from the model picker inside a connected chat.")
        }
    }
}
struct DataSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var exportURL: URL?
    @State private var status = ""
    var body: some View {
        Page(title: "Data", subtitle: "Your data stays with your existing Vesper services.") {
            GlassCard { VStack(alignment: .leading, spacing: 16) {
                Text("Device credentials are stored in the iOS Keychain. This app does not copy web browser credentials automatically.").font(.subheadline)
                Button("Prepare document export") {
                    do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vesper-documents.json"); try JSONEncoder.pretty.encode(JSONValue.object(store.documents)).write(to: url, options: [.atomic, .completeFileProtection]); exportURL = url }
                    catch { status = error.localizedDescription }
                }.disabled(!store.connected)
                if let exportURL { ShareLink("Share export", item: exportURL) }
                Text("Export includes synced documents. Chat history, media files and server memory are not included.").font(.caption).foregroundStyle(VesperTheme.muted)
                if !status.isEmpty { Text(status).font(.caption) }
            }}
        }
    }
}

enum VoiceConfiguration {
    static func normalized(_ original: JSONValue) -> JSONValue {
        var value = original
        guard var url = URLComponents(string: original["baseUrl"].string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else { return value }
        let isMini = original["provider"].string.lowercased().contains("minimax") || (url.host ?? "").contains("minimax")
        if isMini && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("t2a_v2") {
            let group = original["groupId"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty, !(url.queryItems ?? []).contains(where: { $0.name == "GroupId" }) { url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "GroupId", value: group)] }
            value["endpoint"] = .string(url.string ?? "")
            url.path = ""; url.query = nil; url.fragment = nil
            value["baseUrl"] = .string(url.string ?? original["baseUrl"].string)
        }
        return value
    }
    static func failure(_ data: Data, response: URLResponse, connection: JSONValue) -> String {
        let payload = try? JSONDecoder().decode(JSONValue.self, from: data)
        var detail = payload?["error"].string ?? ""
        if detail.isEmpty { detail = "Voice service request failed" }
        let key = connection["apiKey"].string
        if !key.isEmpty { detail = detail.replacingOccurrences(of: key, with: "[redacted]") }
        return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): " + String(detail.prefix(350))
    }
    @MainActor static func connection(_ store: AppStore) -> JSONValue {
        let saved = CredentialStore.read(account: "call-voice-configuration")
        if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(saved.utf8)) { return value }
        return store.document("connections")["Agent 声音"]
    }
}
struct VoiceSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var preview = CallVoice()
    @State private var provider = "ElevenLabs"
    @State private var baseURL = "https://api.elevenlabs.io"
    @State private var apiKey = ""
    @State private var voiceID = ""
    @State private var model = "eleven_multilingual_v2"
    @State private var groupID = ""
    @State private var speed = 1.0
    @State private var status = ""
    private var configuration: JSONValue { .object(["provider": .string(provider), "baseUrl": .string(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), "apiKey": .string(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)), "voiceId": .string(voiceID.trimmingCharacters(in: .whitespacesAndNewlines)), "model": .string(model), "groupId": .string(groupID), "speed": .string(String(speed))]) }
    var body: some View {
        Page(title: "Voice", subtitle: "Rowan’s voice in audio and video calls.") {
            GlassCard { VStack(alignment: .leading, spacing: 16) {
                Picker("Provider", selection: Binding(get: { provider }, set: { value in provider = value; baseURL = value == "ElevenLabs" ? "https://api.elevenlabs.io" : "https://api.minimax.chat"; model = value == "ElevenLabs" ? "eleven_multilingual_v2" : "speech-2.6-hd"; voiceID = ""; apiKey = ""; groupID = "" })) { Text("ElevenLabs").tag("ElevenLabs"); Text("MiniMax").tag("MiniMax") }
                FormField(label: "API address", text: $baseURL)
                Text("API key").font(.caption)
                SecureField("API key", text: $apiKey).foregroundStyle(VesperTheme.ink).padding(12).background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                FormField(label: "Voice ID", text: $voiceID)
                FormField(label: "Model", text: $model)
                if provider == "MiniMax" { FormField(label: "Group ID (optional)", text: $groupID) }
                HStack { Text("Speed"); Slider(value: $speed, in: 0.7...1.2, step: 0.05); Text(String(format: "%.2f×", speed)).font(.caption) }
                Button("Save voice") { save() }.buttonStyle(.bordered)
                Button(preview.speaking ? "Stop preview" : "Preview voice") { if preview.speaking { preview.stop() } else if validate() { Task { await preview.play("宝贝，我在这里。", store: store, connectionOverride: configuration) } } }.buttonStyle(.bordered)
                Text("Saved in this iPhone’s Keychain and used for call replies. Preview uses your provider’s credits.").font(.caption).foregroundStyle(VesperTheme.muted)
                if !status.isEmpty { Text(status).font(.caption) }
                if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled() }
        }.onAppear {
            let saved = VoiceConfiguration.connection(store)
            if !saved["provider"].string.isEmpty { provider = saved["provider"].string }
            if !saved["baseUrl"].string.isEmpty { baseURL = saved["baseUrl"].string }
            apiKey = saved["apiKey"].string; voiceID = saved["voiceId"].string; groupID = saved["groupId"].string
            if !saved["model"].string.isEmpty { model = saved["model"].string }
            speed = min(1.2, max(0.7, Double(saved["speed"].string) ?? 1))
        }.onDisappear { preview.stop() }
    }
    private func validate() -> Bool {
        do { _ = try APIClient.validatedURL(baseURL, path: "") } catch { status = error.localizedDescription; return false }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter an API key and Voice ID."; return false }
        status = ""; return true
    }
    private func save() {
        guard validate() else { return }
        do { let data = try JSONEncoder().encode(configuration); try CredentialStore.save(String(decoding: data, as: UTF8.self), account: "call-voice-configuration"); status = "Saved. New call replies use this voice." }
        catch { status = error.localizedDescription }
    }
}

struct ToolsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [JSONValue] = []
    @State private var status = ""
    @State private var editing: JSONValue?
    var body: some View {
        Page(title: "Tools", subtitle: "Manage the tools available to Vesper.") {
            NavigationLink { VesperConnectorView() } label: { GlassCard { Label("Connect Rowan to Vesper", systemImage: "link.badge.plus").font(.headline) } }.buttonStyle(.plain)
            Button { editing = .object(["id": .string(UUID().uuidString), "enabled": .bool(true), "authMode": .string("none")]) } label: { Label("Add MCP server", systemImage: "plus").frame(minHeight: 44) }
            if !status.isEmpty { Text(status).font(.caption) }
            ForEach(items) { item in
                Button { editing = item } label: {
                    GlassCard { VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(item["name"].string).font(.headline); Spacer(); Image(systemName: "pencil") }
                        Text(item["url"].string).font(.caption).lineLimit(2)
                        Text("\(item["enabled"].bool ? "Enabled" : "Disabled") · \(item["tools"].array.count) tools · \(item["authMode"].string)").font(.caption).foregroundStyle(VesperTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading) }
                }.buttonStyle(.plain)
            }
            if items.isEmpty { Text("Add a server to make its tools available in new chats.").font(.caption) }
        }.task { await load() }.refreshable { await load() }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { item in McpEditor(item: item, existing: items.contains { $0.id == item.id }) }
    }
    private func load() async {
        do { let result = try await store.api.request("/api/mcp/connections"); items = result["connections"].array; status = "" }
        catch { status = error.localizedDescription }
    }
}

private struct McpEditor: View {
    let item: JSONValue
    let existing: Bool
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var auth = "none"
    @State private var token = ""
    @State private var enabled = true
    @State private var busy = false
    @State private var status = ""
    @State private var deleting = false
    @StateObject private var oauth = McpOAuthSession()
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("HTTPS MCP URL", text: $url).keyboardType(.URL)
                Toggle("Enabled", isOn: $enabled)
                Picker("Authentication", selection: $auth) { Text("None").tag("none"); Text("Bearer token").tag("bearer"); Text("OAuth").tag("oauth") }
                if auth == "bearer" { SecureField(existing ? "Token (blank keeps saved token)" : "Access token", text: $token) }
                if auth == "oauth" {
                    Text("Connect to open the service’s authorization page. After approval, Vesper will test and save the connection automatically.").font(.caption)
                    Button("Connect & authorize") { Task { await save(authorize: true) } }.disabled(busy)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
                if existing { Section { Button("Remove server", role: .destructive) { deleting = true }.disabled(busy) } }
            }.disabled(busy).textInputAutocapitalization(.never).autocorrectionDisabled().scrollContentBackground(.hidden).background { Background() }
                .navigationTitle(existing ? "Edit MCP" : "Add MCP").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "Connecting…" : (auth == "oauth" && !item["authorized"].bool ? "Connect & authorize" : "Save & test")) { Task { await save() } }.disabled(busy) }
                }
                .confirmationDialog("Remove this MCP connection?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { Task { await remove() } }
                }
        }.onAppear { name = item["name"].string; url = item["url"].string; auth = item["authMode"].string; enabled = item["enabled"].bool }
            .interactiveDismissDisabled(busy)
    }
    @MainActor private func save(authorize: Bool = false) async {
        guard !busy else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter a name."; return }
        do { _ = try APIClient.validatedURL(url, path: "") } catch { status = error.localizedDescription; return }
        if existing, url.trimmingCharacters(in: .whitespacesAndNewlines) != item["url"].string, auth == "bearer", token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { status = "Enter credentials for the new URL before saving."; return }
        busy = true; status = ""; defer { busy = false }
        if auth == "oauth", authorize || !item["authorized"].bool || item["authMode"].string != "oauth" || url.trimmingCharacters(in: .whitespacesAndNewlines) != item["url"].string {
            do { token = try await oauth.authorize(api: store.api, resource: url.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { status = error.localizedDescription; return }
        }
        var body: JSONValue = .object(["id": .string(item.id), "name": .string(name), "url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines)), "enabled": .bool(enabled), "authMode": .string(auth)])
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["token"] = .string(token.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if auth == "none" { body["clearToken"] = .bool(true) }
        do { let result = try await store.api.request("/api/mcp/connections", method: "PUT", body: body); guard result["connection"].id == item.id else { throw ServiceError(message: "The server did not confirm this connection.") }; dismiss() }
        catch { status = error.localizedDescription }
    }
    private func remove() async {
        busy = true; defer { busy = false }
        guard let id = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        do { _ = try await store.api.request("/api/mcp/connections?id=\(id)", method: "DELETE"); dismiss() }
        catch { status = error.localizedDescription }
    }
}


@MainActor
private final class McpOAuthSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ServiceError(message: "Could not start a secure authorization session.")
        }
        return base64URL(Data(bytes))
    }
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func authorize(api: APIClient, resource: String) async throws -> String {
        let redirect = try APIClient.validatedURL(api.baseURL, path: "/mcp/oauth/callback?native=1").absoluteString
        let metadata = try await api.request("/api/mcp/oauth/discover", method: "POST", body: .object([
            "url": .string(resource), "redirectUri": .string(redirect)
        ]))
        guard !metadata["clientId"].string.isEmpty else {
            throw ServiceError(message: "This service requires a registered OAuth client ID. Automatic registration is unavailable.")
        }
        let verifier = try randomValue()
        let state = try randomValue()
        guard var authorization = URLComponents(string: metadata["authorizationUrl"].string),
              authorization.scheme == "https", authorization.host != nil,
              authorization.user == nil, authorization.password == nil else {
            throw ServiceError(message: "The service returned an invalid authorization address.")
        }
        let values = ["response_type": "code", "client_id": metadata["clientId"].string,
                      "redirect_uri": redirect, "state": state, "code_challenge_method": "S256",
                      "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
                      "scope": metadata["scopes"].string, "resource": metadata["resource"].string]
        authorization.queryItems = (authorization.queryItems ?? []).filter { values[$0.name] == nil }
            + values.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let address = authorization.url else { throw ServiceError(message: "Invalid authorization address.") }
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.first { $0.isKeyWindow }
        guard anchor != nil else { throw ServiceError(message: "Open Vesper before connecting this service.") }
        defer { session = nil; anchor = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let browser = ASWebAuthenticationSession(url: address, callbackURLScheme: "vesper") { url, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: ServiceError(message: "Authorization cancelled. Your entries are still here."))
                    } else { continuation.resume(throwing: error) }
                } else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: ServiceError(message: "Authorization returned no result.")) }
            }
            browser.presentationContextProvider = self
            self.session = browser
            if !browser.start() { continuation.resume(throwing: ServiceError(message: "Could not open the authorization window.")) }
        }
        guard callback.scheme == "vesper", callback.host == "oauth", callback.path == "/callback",
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw ServiceError(message: "Unexpected authorization callback.")
        }
        let query = parts.queryItems ?? []
        func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
        guard query.filter({ $0.name == "state" }).count == 1, value("state") == state else {
            throw ServiceError(message: "Authorization session did not match. Please reconnect.")
        }
        let oauthError = value("error")
        if !oauthError.isEmpty {
            let description = value("error_description")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = description.isEmpty
                ? oauthError.replacingOccurrences(of: "_", with: " ")
                : description
            throw ServiceError(message: "Authorization failed: \(reason.prefix(240))")
        }
        guard query.filter({ $0.name == "code" }).count == 1, !value("code").isEmpty else {
            throw ServiceError(message: "The service returned no authorization code.")
        }
        let result = try await api.request("/api/mcp/oauth", method: "POST", body: .object([
            "tokenUrl": metadata["tokenUrl"], "clientId": metadata["clientId"], "clientSecret": metadata["clientSecret"],
            "code": .string(value("code")), "verifier": .string(verifier), "redirectUri": .string(redirect), "resource": metadata["resource"]
        ]))
        guard !result["accessToken"].string.isEmpty else { throw ServiceError(message: "Authorization returned no access token.") }
        return result["accessToken"].string
    }
}

private struct VesperConnectorView: View {
    @EnvironmentObject private var store: AppStore
    @State private var token = CredentialStore.read(account: "vesper-mcp-owner")
    @State private var status = ""
    @State private var busy = false
    @State private var confirming = false
    private let endpoint = "https://mcp.vesper.r-vera.com/mcp"
    var body: some View {
        Page(title: "Vesper MCP", subtitle: "Let Rowan access your Vesper through a connector.") {
            GlassCard { VStack(alignment: .leading, spacing: 16) {
                Text("MCP URL").font(.caption)
                Text(endpoint).font(.subheadline).textSelection(.enabled)
                Button("Copy MCP URL") { UIPasteboard.general.string = endpoint; status = "URL copied" }
                SecureField("MCP access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Test existing token") { Task { await test() } }.disabled(busy || token.isEmpty)
                Button("Set this token on Vesper") { confirming = true }.disabled(busy || token.isEmpty)
                Button("Copy token") { UIPasteboard.general.string = token; status = "Token copied" }.disabled(token.isEmpty)
                Text("Use this URL and Bearer token when adding Vesper to ChatGPT. This token is separate from your device pairing token.").font(.caption).foregroundStyle(VesperTheme.muted)
                if !status.isEmpty { Text(status).font(.caption) }
            } }
        }.confirmationDialog("Replace Vesper’s MCP access token? Existing connectors using the old token will need updating.", isPresented: $confirming, titleVisibility: .visible) {
            Button("Set token") { Task { await setup() } }
        }
    }
    private func test() async {
        busy = true; defer { busy = false }
        do {
            let result = try await store.api.request("/api/mcp", method: "POST", body: .object(["url": .string(endpoint), "token": .string(token.trimmingCharacters(in: .whitespacesAndNewlines))]))
            try CredentialStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: "vesper-mcp-owner")
            status = "Connected · \(Int(result["toolCount"].number)) tools"
        } catch { status = error.localizedDescription }
    }
    private func setup() async {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...256).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { status = "Use 16–256 letters, numbers, underscores or hyphens."; return }
        busy = true
        do { _ = try await store.api.request("/api/mcp/owner-token", method: "POST", body: .object(["token": .string(value)])); try CredentialStore.save(value, account: "vesper-mcp-owner"); status = "Token saved. Test it before connecting." }
        catch { status = error.localizedDescription }
        busy = false
    }
}

struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var loaded = false
    @State private var busy = false
    @State private var error = ""
    private var statusText: String {
        guard loaded else { return "Checking permission…" }
        switch authorization {
        case .notDetermined: return "Not requested"
        case .denied: return "Notifications are off"
        case .authorized: return "Notifications are allowed"
        case .provisional: return "Quiet notifications are allowed"
        case .ephemeral: return "Temporary permission"
        @unknown default: return "Unknown permission status"
        }
    }
    var body: some View {
        PermissionPage(title: "Notifications") {
            PermissionPanel { VStack(alignment: .leading, spacing: 18) {
                Text(statusText).font(.headline)
                Text("Allows date reminders and opening reminders for letters synced to this phone, even when the app is closed. Open Vesper to sync newly received letters. Remote push for unsynced letters and new chat replies is not connected yet.").font(.subheadline).foregroundStyle(VesperTheme.muted)
                if loaded && authorization == .notDetermined {
                    Button { Task { await requestPermission() } } label: {
                        Text(busy ? "Requesting…" : "Allow notifications")
                    }.buttonStyle(PermissionActionStyle()).disabled(busy)
                } else if loaded {
                    Button("Open notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }.buttonStyle(PermissionActionStyle())
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            } }
        }.task(id: scenePhase) { if scenePhase == .active { await refreshPermission() } }
    }
    @MainActor private func refreshPermission() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        loaded = true
    }
    @MainActor private func requestPermission() async {
        guard !busy else { return }
        busy = true; error = ""
        defer { busy = false }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { self.error = error.localizedDescription }
        await refreshPermission()
    }
}
