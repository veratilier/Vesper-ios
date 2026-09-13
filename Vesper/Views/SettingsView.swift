import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Page(title: "Settings", subtitle: "Make Vesper feel like you.") {
            NavigationLink { ConnectionView() } label: { settingsRow("Connection", subtitle: store.connected ? "Connected to your Vesper" : "Pair this device", icon: "network") }
            NavigationLink { WakeView() } label: { settingsRow("Autonomous Wake", subtitle: "Schedule, prompt and recent activity", icon: "sparkles") }
            NavigationLink { VoiceSettingsView() } label: { settingsRow("Voice", subtitle: "ElevenLabs and MiniMax for calls", icon: "waveform") }
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
                Text("Device token").font(.caption).foregroundStyle(VesperTheme.muted)
                SecureField("Device token", text: $store.token).foregroundStyle(VesperTheme.ink).textContentType(.password).padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                Button { Task { await store.connect() } } label: { HStack { if store.loading { ProgressView() }; Text(store.loading ? "Connecting…" : "Save and connect") }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44).background(VesperTheme.ink, in: Capsule()) }.buttonStyle(.plain).disabled(store.loading)
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
    @State private var loaded = false
    private var version: Double { runtime["configVersion"].number }
    var body: some View {
        Page(title: "Autonomous Wake", subtitle: "A little room for initiative.") {
            GlassCard { VStack(alignment: .leading, spacing: 18) {
                if !loaded { Text(status.isEmpty ? "Checking wake service…" : "Could not load the wake service.").font(.subheadline) }
                else if version < 1 { Text("The server responded, but this version does not support changing wake settings. Update the VPS wake service first.").font(.subheadline) }
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                Button("Check service again") { Task { await load() } }.disabled(busy)
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
        busy = true; defer { busy = false }
        do { runtime = try await store.api.request("/wake", history: true); loaded = true; enabled = runtime["config"]["enabled"].bool; interval = Int(runtime["config"]["intervalMinutes"].number); prompt = runtime["prompt"].string; status = "" }
        catch { loaded = false; runtime = .null; status = "Wake service: " + error.localizedDescription }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            var body: JSONValue = .object(["action": .string("configure"), "enabled": .bool(enabled), "intervalMinutes": interval == 0 ? .null : .number(Double(interval))])
            if version >= 2 { body["prompt"] = .string(prompt) }
            let result = try await store.api.request("/wake", method: "POST", body: body, history: true)
            guard result["configVersion"].number >= 1, result["config"] != .null else { throw ServiceError(message: "The background service needs an update.") }
            if version >= 2 && result["prompt"].string != prompt { throw ServiceError(message: "The server did not confirm the saved prompt.") }
            runtime = result; enabled = result["config"]["enabled"].bool; interval = Int(result["config"]["intervalMinutes"].number); status = "Saved. Changes apply from the next run."
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
    static func connection(_ store: AppStore) -> JSONValue {
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
                SecureField("API key", text: $apiKey).foregroundStyle(VesperTheme.ink).padding(12).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
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
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("HTTPS MCP URL", text: $url).keyboardType(.URL)
                Toggle("Enabled", isOn: $enabled)
                Picker("Authentication", selection: $auth) { Text("None").tag("none"); Text("Bearer token").tag("bearer"); Text("OAuth").tag("oauth") }
                if auth != "none" { SecureField(existing ? "Token (blank keeps saved token)" : "Access token", text: $token) }
                if auth == "oauth" {
                    Text("Authorize OAuth services in Vesper’s web settings, then return and refresh. Existing authorization is preserved when the token field is blank.").font(.caption)
                    Link("Open web settings for authorization", destination: URL(string: "https://vesper.r-vera.com")!)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
                if existing { Section { Button("Remove server", role: .destructive) { deleting = true }.disabled(busy) } }
            }.textInputAutocapitalization(.never).autocorrectionDisabled().scrollContentBackground(.hidden).background { Background() }
                .navigationTitle(existing ? "Edit MCP" : "Add MCP").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "Connecting…" : "Save & test") { Task { await save() } }.disabled(busy) }
                }
                .confirmationDialog("Remove this MCP connection?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { Task { await remove() } }
                }
        }.onAppear { name = item["name"].string; url = item["url"].string; auth = item["authMode"].string; enabled = item["enabled"].bool }
            .interactiveDismissDisabled(busy)
    }
    private func save() async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter a name."; return }
        do { _ = try APIClient.validatedURL(url, path: "") } catch { status = error.localizedDescription; return }
        if existing, url.trimmingCharacters(in: .whitespacesAndNewlines) != item["url"].string, auth != "none", token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { status = "Enter credentials for the new URL before saving."; return }
        busy = true; defer { busy = false }
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
