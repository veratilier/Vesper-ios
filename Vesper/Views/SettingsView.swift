import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Page(title: "Settings", subtitle: "Make Vesper feel like you.") {
            NavigationLink { ConnectionView() } label: { settingsRow("Connection", subtitle: store.connected ? "Connected to your Vesper" : "Pair this device", icon: "network") }
            NavigationLink { WakeView() } label: { settingsRow("Autonomous Wake", subtitle: "Schedule, prompt and recent activity", icon: "sparkles") }
            NavigationLink { AgentSettingsView() } label: { settingsRow("Agent", subtitle: "Instructions and model information", icon: "person.crop.circle") }
            NavigationLink { ToolsView() } label: { settingsRow("Tools", subtitle: "Connected MCP services", icon: "link") }
            NavigationLink { DataSettingsView() } label: { settingsRow("Data", subtitle: "Export and privacy", icon: "archivebox") }
        }.buttonStyle(.plain)
    }
    private func settingsRow(_ title: String, subtitle: String, icon: String) -> some View {
        GlassCard { HStack(spacing: 14) { Image(systemName: icon).frame(width: 42, height: 42).background(VesperTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(VesperTheme.muted) }; Spacer(); Image(systemName: "chevron.right").font(.caption) } }
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
                SecureField("Device token", text: $store.token).textContentType(.password).padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                Button { Task { await store.connect() } } label: { HStack { if store.loading { ProgressView() }; Text(store.loading ? "Connecting…" : "Save and connect") }.frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(store.loading)
                Text(store.connected ? "Connected" : "Not connected").font(.caption).foregroundStyle(VesperTheme.muted)
            }.textInputAutocapitalization(.never).autocorrectionDisabled() }
        }
    }
}
struct WakeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var runtime: JSONValue = .null
    @State private var enabled = false
    @State private var interval = 0
    @State private var prompt = ""
    @State private var busy = false
    @State private var status = ""
    private var version: Double { runtime["configVersion"].number }
    var body: some View {
        Page(title: "Autonomous Wake", subtitle: "A little room for initiative.") {
            GlassCard { VStack(alignment: .leading, spacing: 18) {
                Toggle("Automatic wake-up", isOn: $enabled).disabled(version < 1 || busy)
                Picker("Interval", selection: $interval) {
                    Text("Adaptive").tag(0)
                    ForEach([30,60,120,240,360,720,1440], id: \.self) { Text("\($0) minutes").tag($0) }
                }.disabled(version < 1 || busy)
                Text("Active chats and quiet requests may postpone a wake-up.").font(.caption).foregroundStyle(VesperTheme.muted)
                FormField(label: "Wake prompt", text: $prompt, multiline: true).disabled(version < 2 || busy)
                Text("\(prompt.unicodeScalars.count) / \(max(8000, Int(runtime["promptMaxLength"].number)))").font(.caption)
                if version < 2 { Text("The background service must support prompt editing before this field can be saved.").font(.caption) }
                Button("Restore default prompt") { prompt = runtime["defaultPrompt"].string }.disabled(version < 2 || busy)
                Button(busy ? "Saving…" : "Save settings") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(version < 1 || busy || (version >= 2 && (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.unicodeScalars.count > max(8000, Int(runtime["promptMaxLength"].number)))))
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            }}
            Text("Recent activity").font(VesperTheme.title(30))
            if runtime["jobs"].array.isEmpty { EmptyCard(title: "No activity to show", message: "Pull to refresh the latest server history.") }
            ForEach(runtime["jobs"].array) { job in
                GlassCard { DisclosureGroup {
                    Text(job["decision"].string).font(.subheadline).textSelection(.enabled)
                    ForEach(Array(job["calls"].array.enumerated()), id: \.offset) { _, call in Text("\(call["name"].string) · \(call["status"].string)").font(.caption) }
                } label: { VStack(alignment: .leading, spacing: 5) { Text(job["status"].string); Text(Date(timeIntervalSince1970: job["created"].number).formatted()).font(.caption).foregroundStyle(VesperTheme.muted) } } }
            }
        }.task { await load() }.refreshable { await load() }
    }
    private func load() async {
        guard !busy else { return }
        do { runtime = try await store.api.request("/wake", history: true); enabled = runtime["config"]["enabled"].bool; interval = Int(runtime["config"]["intervalMinutes"].number); prompt = runtime["prompt"].string; status = "" }
        catch { status = error.localizedDescription }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            var body: JSONValue = .object(["action": .string("configure"), "enabled": .bool(enabled), "intervalMinutes": interval == 0 ? .null : .number(Double(interval))])
            if version >= 2 { body["prompt"] = .string(prompt) }
            let result = try await store.api.request("/wake", method: "POST", body: body, history: true)
            guard result["configVersion"].number >= 1, result["config"] != .null else { throw ServiceError(message: "The background service needs an update.") }
            if version >= 2 && result["prompt"].string != prompt { throw ServiceError(message: "The server did not confirm the saved prompt.") }
            runtime = result; status = "Saved. Changes apply from the next run."
        } catch { status = error.localizedDescription }
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
struct ToolsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [JSONValue] = []
    @State private var status = ""
    var body: some View {
        Page(title: "Tools", subtitle: "Your existing Vesper connections.") {
            if !status.isEmpty { Text(status).font(.subheadline) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GlassCard { VStack(alignment: .leading, spacing: 8) { Text(item["name"].string.isEmpty ? item["label"].string : item["name"].string).font(.headline); Text(item["description"].string).font(.caption); Text(item["status"].string).font(.caption).foregroundStyle(VesperTheme.muted) } }
            }
            if items.isEmpty { EmptyCard(title: "Connections", message: "No connections loaded. Existing server-side tools are registered when you start a new chat.") }
        }.task {
            do { let r = try await store.api.request("/api/mcp/connections"); items = r["connections"].array; if items.isEmpty { items = r["servers"].array } }
            catch { status = error.localizedDescription }
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
