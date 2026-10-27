import SwiftUI

struct UsageView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var gpt = UsageLoadState<GPTUsageSnapshot>()
    @StateObject private var eleven = UsageLoadState<ElevenLabsUsageSnapshot>()
    @State private var editingKey = false
    @State private var credentialRevision = 0
    private var gptIdentity: String { UsageCredentials.fingerprint([store.socketURL, store.token]) }
    private var elevenKey: String { UsageCredentials.elevenLabs(store) }
    private var elevenIdentity: String { UsageCredentials.fingerprint([elevenKey]) }

    var body: some View {
        Page(title: "Usage", subtitle: "Your account limits and voice balance.", showsTitle: false) {
            gptCard
            elevenCard
            miniMaxCard
        }
        .background { Background() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: gptIdentity) { await refreshGPT() }
        .task(id: elevenIdentity + String(credentialRevision)) { await refreshElevenLabs() }
        .refreshable {
            async let first: Void = refreshGPT()
            async let second: Void = refreshElevenLabs()
            _ = await (first, second)
        }
        .sheet(isPresented: $editingKey, onDismiss: { credentialRevision += 1 }) {
            ElevenLabsUsageKeyView()
        }
    }

    private var gptCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                heading("GPT", subtitle: "Weekly quota", loading: gpt.loading) {
                    Task { await refreshGPT() }
                }
                if let quota = gpt.value {
                    metrics(used: percent(quota.usedPercent), remaining: percent(quota.remainingPercent))
                    ProgressView(value: min(100, quota.usedPercent), total: 100).tint(VesperTheme.accent)
                        .accessibilityLabel("GPT weekly quota used").accessibilityValue(percent(quota.usedPercent))
                    resetDate(quota.resetsAt)
                } else {
                    Text(gpt.loading ? "Reading weekly quota…" : "Weekly quota unavailable")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                footer(updatedAt: gpt.updatedAt, error: gpt.error, loading: gpt.loading) { Task { await refreshGPT() } }
                Text("Shared with the ChatGPT/Codex account connected to Vesper. This is a usage limit, not a cash balance.")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }
        }
    }

    private var elevenCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                heading("ElevenLabs", subtitle: "Current billing period", loading: eleven.loading) {
                    Task { await refreshElevenLabs() }
                }
                if let quota = eleven.value {
                    metrics(used: count(quota.used), remaining: count(quota.remaining))
                    Text("of \(count(quota.limit)) subscription characters").font(.caption).foregroundStyle(VesperTheme.muted)
                    if let fraction = quota.fractionUsed {
                        ProgressView(value: fraction).tint(VesperTheme.accent)
                            .accessibilityLabel("ElevenLabs subscription quota used")
                    }
                    if quota.used > quota.limit {
                        Text("Usage exceeds the included allowance.").font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                    if let amount = quota.overageAmount, let currency = quota.overageCurrency {
                        LabeledContent("Current overage", value: amount.formatted(.currency(code: currency)))
                            .font(.subheadline)
                    }
                    resetDate(quota.resetsAt)
                } else {
                    Text(eleven.loading ? "Reading subscription…" : "Subscription usage unavailable")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                footer(updatedAt: eleven.updatedAt, error: eleven.error, loading: eleven.loading) { Task { await refreshElevenLabs() } }
                Button { editingKey = true } label: { Label("ElevenLabs access", systemImage: "key") }
                    .accessibilityIdentifier("usage.elevenlabs.access")
                Text("Account-wide usage, including other apps. Included allowance and extra charges are shown separately.")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }
        }
    }

    private var miniMaxCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("MiniMax").font(.title3.weight(.semibold))
                Text("View your spend, remaining balance and voice packages in the official billing console.")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
                Link(destination: URL(string: "https://platform.minimax.cn/user-center/payment/balance")!) {
                    Label("China billing", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://platform.minimax.io/user-center/payment/balance")!) {
                    Label("International billing", systemImage: "arrow.up.right.square")
                }
                Text("Sign in to the region where you bought your credits. MiniMax balance is not automatically synced here.")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }
        }
    }

    private func heading(_ title: String, subtitle: String, loading: Bool, refresh: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Spacer()
            Button(action: refresh) {
                if loading { ProgressView().frame(width: 44, height: 44) }
                else { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
            }.disabled(loading).accessibilityLabel("Refresh \(title) usage")
        }
    }
    private func metrics(used: String, remaining: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { metric("Used", value: used); Spacer(minLength: 0); metric("Remaining", value: remaining) }
            VStack(alignment: .leading, spacing: 12) { metric("Used", value: used); metric("Remaining", value: remaining) }
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(VesperTheme.muted)
            Text(value).font(.title2.weight(.medium)).monospacedDigit().fixedSize(horizontal: true, vertical: false)
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private func resetDate(_ date: Date?) -> some View {
        if let date { Text("Resets " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(VesperTheme.muted) }
    }
    @ViewBuilder private func footer(updatedAt: Date?, error: String?, loading: Bool, retry: @escaping () -> Void) -> some View {
        if let error {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.caption)
                Button("Retry", action: retry).disabled(loading)
            }
        }
        if let updatedAt {
            Text((error == nil ? "Updated " : "Last successful update ") + updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(VesperTheme.muted)
        }
    }
    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + "%" }
    private func count(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
    private func refreshGPT() async {
        let api = store.api, endpoint = store.socketURL
        await gpt.load(identity: gptIdentity) { try await GPTUsageReader.fetch(api: api, endpoint: endpoint) }
    }
    private func refreshElevenLabs() async {
        let key = elevenKey
        await eleven.load(identity: UsageCredentials.fingerprint([key])) {
            guard !key.isEmpty else { throw UsageReadError.unavailable("Add ElevenLabs access below, or configure an ElevenLabs voice in Settings.") }
            return try await ElevenLabsUsageClient().fetch(apiKey: key)
        }
    }
}

private struct ElevenLabsUsageKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = CredentialStore.read(account: UsageCredentials.elevenLabsAccount)
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Page(title: "ElevenLabs access", showsTitle: false) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Use a key with subscription read permission. It is stored in this device’s Keychain and sent only to ElevenLabs.")
                            .font(.subheadline)
                        SecureField("ElevenLabs API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 12))
                        Text("Leave blank to use your existing ElevenLabs voice key, if available. This does not change your voice settings.")
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }.background { Background() }.transparentNavigationTop()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                }
        }
    }
    private func save() {
        do {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { try CredentialStore.delete(account: UsageCredentials.elevenLabsAccount) }
            else {
                _ = try ElevenLabsUsageClient.request(apiKey: trimmed)
                try CredentialStore.save(trimmed, account: UsageCredentials.elevenLabsAccount)
            }
            dismiss()
        } catch { self.error = "Could not save the key. Check its format and try again." }
    }
}

private enum StudioTypography {
    static let section = Font.headline.weight(.semibold)
    static let title = Font.subheadline.weight(.semibold)
    static let value = Font.title3.weight(.semibold)
    static let detail = Font.footnote
    static let note = Font.caption
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}

/// Studio combines live readings with the gateway connection status.
struct StudioView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var gpt = UsageLoadState<GPTUsageSnapshot>()
    @StateObject private var eleven = UsageLoadState<ElevenLabsUsageSnapshot>()
    @State private var wake: JSONValue = .null
    @State private var wakeJobs: [JSONValue] = []
    @State private var wakeHistoryLoaded = false
    @State private var wakeHistoryComplete = false
    @State private var activityError = ""
    @State private var activityUpdatedAt: Date?
    @State private var loadingActivity = false
    @State private var serverStatus: JSONValue = .null
    @State private var serverUpdatedAt: Date?
    @State private var serverError = ""
    @State private var gatewayStatus: JSONValue = .null
    @State private var gatewayError = ""
    @State private var cachedUsageMessages: [JSONValue] = []
    @State private var contextSnapshot: ChatContextUsageSnapshot?
    @ScaledMetric(relativeTo: .body) private var limitCardContentHeight: CGFloat = 112
    @ScaledMetric(relativeTo: .subheadline) private var metricTitleHeight: CGFloat = 38
    @State private var updatingRules = false
    @State private var ruleError = ""
    @State private var editingCompaction = false
    @State private var compactionDraft = ""
    @State private var compactionExpected = 0
    @State private var savingCompaction = false
    @State private var compactionError = ""
    @AppStorage("studioVPSRenewalTimestamp") private var renewalTimestamp = 0.0
    @State private var editingRenewal = false
    @State private var renewalDraft = Date()
    private var gptIdentity: String { UsageCredentials.fingerprint([store.socketURL, store.token]) }
    private var elevenKey: String { UsageCredentials.elevenLabs(store) }
    private var elevenIdentity: String { UsageCredentials.fingerprint([elevenKey]) }
    private var vpsToken: String {
        let saved = CredentialStore.read(account: VesperBackend.vps.credentialAccount)
        return saved.isEmpty && store.activeBackend == .vps ? store.token : saved
    }
    private var vpsIdentity: String {
        UsageCredentials.fingerprint([BackendConnection.load(.vps).historyURL,
                                      vpsToken])
    }
    private var contextConversationID: String {
        if !chat.messages.isEmpty { return chat.conversationID }
        return ChatRecentCache.mainID(api: store.api) ?? chat.conversationID
    }
    private var contextIdentity: String {
        UsageCredentials.fingerprint([store.historyURL, store.token, contextConversationID])
    }
    private var todayStart: TimeInterval { JournalDates.calendar.startOfDay(for: .now).timeIntervalSince1970 }
    private var monthStart: TimeInterval {
        JournalDates.calendar.dateInterval(of: .month, for: .now)?.start.timeIntervalSince1970 ?? todayStart
    }
    private var todayWakes: [JSONValue] {
        wakeJobs.filter { $0["source"].string == "automation" && $0["created"].number >= todayStart }
    }
    private var monthWakes: [JSONValue] {
        wakeJobs.filter { $0["source"].string == "automation" && $0["created"].number >= monthStart }
    }
    private var loadedChatCacheRate: Double? {
        let source = chat.messages.isEmpty ? cachedUsageMessages : chat.messages
        let samples = source.compactMap { message -> ChatTokenUsage? in
            let value = message["metadata"]["tokenUsage"]
            guard value["complete"].bool, value["scope"].string != "latestRequest" else { return nil }
            return ChatTokenUsage(value)
        }
        let reported = samples.filter { $0.cached != nil }
        let input = reported.reduce(0) { $0 + $1.input }
        let cached = reported.compactMap(\.cached).reduce(0, +)
        return input > 0 ? Double(cached) / Double(input) : nil
    }
    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: StudioTypography.spacing),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Studio").font(.system(size: 29, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Button { Task { await refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                            .vesperGlass(in: Circle(), interactive: true)
                    }.buttonStyle(.plain).disabled(loadingActivity || gpt.loading || eleven.loading)
                        .accessibilityLabel("Refresh Studio")
                }

                sectionLabel("Window", symbol: "rectangle.on.rectangle")
                LazyVGrid(columns: metricColumns, spacing: StudioTypography.spacing) {
                    contextCard
                    Button {
                        compactionExpected = Int(gatewayStatus["compaction"]["thresholdTokens"].number)
                        compactionDraft = String(compactionExpected)
                        compactionError = ""
                        editingCompaction = true
                    } label: {
                        gatewayPolicyCard.overlay(alignment: .topTrailing) {
                            Image(systemName: "pencil").font(.caption.weight(.medium))
                                .foregroundStyle(VesperTheme.muted).padding(16)
                        }
                    }
                        .buttonStyle(.plain)
                        .disabled(!gatewayStatus["compaction"]["editable"].bool)
                        .accessibilityHint("Change the automatic compaction threshold")
                }
                sectionLabel("Usage", symbol: "chart.bar")
                LazyVGrid(columns: metricColumns, spacing: StudioTypography.spacing) {
                    NavigationLink { UsageView() } label: { gptCard }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens account usage details")
                    NavigationLink { UsageView() } label: { elevenCard }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens account usage details")
                }

                sectionLabel("Machine", symbol: "server.rack")
                serverCard
                gatewayCard
                sectionLabel("Heartbeat", symbol: "waveform.path.ecg")
                wakeCard
                sectionLabel("Manage", symbol: "slider.horizontal.3")
                managementCard
                if !activityError.isEmpty {
                    Text(activityError).font(.caption).foregroundStyle(VesperTheme.muted)
                        .accessibilityIdentifier("studio-activity-error")
                }
            }
            .frame(maxWidth: 960).frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 26)
        }
        .background { Background() }
        .accessibilityIdentifier("studio-dashboard")
        .task(id: gptIdentity) { await refreshGPT() }
        .task(id: elevenIdentity) { await refreshElevenLabs() }
        .task(id: store.historyURL + "\n" + store.token) { await refreshActivity() }
        .task(id: vpsIdentity) { await refreshServer() }
        .task(id: vpsIdentity + "\n" + (chat.activeThreadID ?? "")) {
            while !Task.isCancelled {
                await refreshGateway()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .task(id: contextIdentity) {
            contextSnapshot = ChatContextUsageStore.load(api: store.api, conversationID: contextConversationID)
        }
        .onChange(of: chat.contextUsage) { _, usage in
            if let snapshot = ChatContextUsageSnapshot(usage) { contextSnapshot = snapshot }
            Task { await refreshGateway() }
        }
        .task(id: store.historyURL + "\n" + store.token) {
            let api = store.api
            let id = ChatRecentCache.mainID(api: api) ?? chat.conversationID
            cachedUsageMessages = ChatRecentCache.load(api: api, id: id)?["messages"].array ?? []
        }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await refreshActivity(); await refreshServer(); await refreshGateway() } }
        }
        .refreshable { await refreshAll() }
        .sheet(isPresented: $editingRenewal) {
            NavigationStack {
                Form {
                    DatePicker("VPS renewal date", selection: $renewalDraft, displayedComponents: .date)
                }
                .navigationTitle("Renewal date")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingRenewal = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { renewalTimestamp = renewalDraft.timeIntervalSince1970; editingRenewal = false }
                    }
                }
            }
        }
        .sheet(isPresented: $editingCompaction) { compactionEditor }
    }

    private var gatewayCard: some View {
        GlassCard(padding: StudioTypography.padding) {
            VStack(alignment: .leading, spacing: StudioTypography.spacing) {
                HStack(spacing: 8) {
                    Label("Gateway", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(StudioTypography.title)
                    Spacer()
                    Text(gatewayStatus["routeActive"].bool ? "CONNECTED" : (gatewayError.isEmpty ? "CHECKING" : "UNAVAILABLE"))
                        .font(.caption2.weight(.bold)).tracking(0.8)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(VesperTheme.accent.opacity(0.18), in: Capsule())
                }
                HStack(spacing: 6) {
                    routeNode("Vesper", symbol: "iphone")
                    routeArrow
                    routeNode("Gateway", symbol: "point.3.connected.trianglepath.dotted")
                    routeArrow
                    routeNode("Codex", symbol: "sparkles")
                }
                if !gatewayStatus["routeActive"].bool {
                    Text(gatewayError.isEmpty ? "Checking gateway connection…" : gatewayError)
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                }
            }
        }
        .accessibilityIdentifier("studio-gateway-status")
    }

    private func routeNode(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var routeArrow: some View {
        Image(systemName: "arrow.right").font(.caption2.weight(.semibold))
            .foregroundStyle(VesperTheme.muted)
    }

    private var gatewayPolicyCard: some View {
        let isActive = gatewayStatus["compaction"]["enabled"].bool
        let threshold = Int(gatewayStatus["compaction"]["thresholdTokens"].number)
        let reading = isActive && threshold > 0 ? contextSnapshot : nil
        return limitCard(
            "Auto compaction", symbol: "slider.horizontal.3",
            value: isActive && threshold > 0
                ? "\(reading.map { compactTokens($0.inputTokens) } ?? "—")/\(compactTokens(threshold))"
                : (gatewayStatus == .null ? "—" : "Off"),
            progress: reading.map { Double($0.inputTokens) / Double(threshold) },
            footer: "Last · \(lastCompactionLabel)",
            accessibility: "Automatic compaction. Latest request input \(reading.map { String($0.inputTokens) } ?? "unavailable") tokens. Threshold \(threshold) tokens. Last compacted \(lastCompactionLabel). Codex does not expose its internal trigger count."
        )
    }

    private var lastCompactionLabel: String {
        let value = gatewayStatus["compactionActivity"]["lastCompletedAt"].string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard !value.isEmpty, let date = formatter.date(from: value) else { return "Not observed" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: .now)
    }

    private var compactionEditor: some View {
        NavigationStack {
            Form {
                Section("Auto compaction limit") {
                    TextField("Tokens", text: $compactionDraft)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("compaction-limit-field")
                    Text("Choose 20,000–1,000,000 tokens. Codex uses its own context estimate, so the latest request count is only an approximation. Low limits can trigger repeated compaction.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("This is shared by VPS chats and applies to each chat when it next resumes. It does not run a compaction now.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !chat.canSwitchBackend {
                    Text("Wait for the current reply or call to finish.").font(.caption).foregroundStyle(.secondary)
                }
                if !compactionError.isEmpty { Text(compactionError).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Auto compaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingCompaction = false }.disabled(savingCompaction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savingCompaction ? "Saving…" : "Save") { Task { await saveCompactionLimit() } }
                        .disabled(savingCompaction || !chat.canSwitchBackend)
                }
            }
        }
    }

    private func saveCompactionLimit() async {
        let trimmed = compactionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit = Int(trimmed), (20_000...1_000_000).contains(limit) else {
            compactionError = "Enter a whole number between 20,000 and 1,000,000."; return
        }
        guard chat.canSwitchBackend, !vpsToken.isEmpty else {
            compactionError = "Finish the current reply or call and connect the VPS first."; return
        }
        savingCompaction = true; defer { savingCompaction = false }
        do {
            var request = URLRequest(url: URL(string: "https://codex.r-vera.com/gateway/health")!)
            request.httpMethod = "POST"; request.timeoutInterval = 10
            request.setValue("Bearer \(vpsToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(JSONValue.object([
                "thresholdTokens": .number(Double(limit)), "expectedThresholdTokens": .number(Double(compactionExpected))
            ]))
            let session = URLSession(configuration: .ephemeral, delegate: UsageRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError(message: "Gateway response unavailable.") }
            if http.statusCode == 409 {
                await refreshGateway()
                throw ServiceError(message: "The limit changed on another device. Close and reopen this setting to review it.")
            }
            guard http.statusCode == 200,
                  let result = try? JSONDecoder().decode(JSONValue.self, from: data),
                  result["thresholdTokens"].number == Double(limit), result["applies"].string == "next-thread-resume" else {
                throw ServiceError(message: "The gateway did not confirm the limit. Try again.")
            }
            gatewayStatus["compaction"]["thresholdTokens"] = .number(Double(limit))
            chat.refreshThreadPolicyOnNextSend()
            editingCompaction = false
        } catch { compactionError = error.localizedDescription }
    }

    private var contextCard: some View {
        limitCard(
            "Context window", symbol: "text.alignleft",
            value: contextSnapshot.map { "\(compactTokens($0.inputTokens))/\(compactTokens($0.windowTokens))" } ?? "—",
            progress: contextSnapshot?.fraction,
            footer: loadedChatCacheRate.map { "Cache hit · \(Int(($0 * 100).rounded()))%" } ?? "Latest model request",
            accessibility: contextSnapshot.map {
                "Latest request used \($0.inputTokens) of \($0.windowTokens) context tokens, last observed \($0.observedAt.formatted())."
            } ?? "No context window reading yet"
        )
    }
    private var gptCard: some View {
        limitCard(
            "GPT · weekly", symbol: "chart.bar.xaxis",
            value: gpt.value.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—",
            progress: gpt.value.map { $0.remainingPercent / 100 },
            footer: "Remaining",
            accessibility: gpt.value.map { "GPT weekly quota \(Int($0.remainingPercent.rounded())) percent remaining" }
                ?? "GPT weekly quota unavailable"
        )
    }
    private var elevenCard: some View {
        limitCard(
            "ElevenLabs", symbol: "waveform",
            value: eleven.value.map { "\(compactTokens(Int($0.remaining)))/\(compactTokens(Int($0.limit)))" } ?? "—",
            progress: eleven.value.flatMap { $0.fractionUsed.map { 1 - $0 } },
            footer: "Characters left",
            accessibility: eleven.value.map { "ElevenLabs \(Int($0.remaining)) of \(Int($0.limit)) characters remaining" }
                ?? "ElevenLabs quota unavailable"
        )
    }
    private func limitCard(_ title: String, symbol: String, value: String,
                           progress: Double?, footer: String, accessibility: String) -> some View {
        GlassCard(padding: StudioTypography.padding) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(StudioTypography.title)
                Text(title).font(StudioTypography.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: metricTitleHeight, alignment: .topLeading)
                Text(value)
                    .font(StudioTypography.value)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                ProgressView(value: min(max(progress ?? 0, 0), 1))
                    .tint(VesperTheme.accent).opacity(progress == nil ? 0.3 : 1)
                Text(footer)
                    .font(StudioTypography.note).foregroundStyle(VesperTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: limitCardContentHeight, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility)
        }
    }
    private var serverCard: some View {
        GlassCard(padding: StudioTypography.padding) {
            VStack(alignment: .leading, spacing: StudioTypography.spacing) {
                HStack {
                    Label("Machine · VPS", systemImage: "server.rack").font(StudioTypography.title)
                    Spacer()
                    if serverStatus["uptimeSeconds"].number > 0 {
                        Text("Up \(Int(serverStatus["uptimeSeconds"].number / 86400)) days")
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }
                machineMetric("CPU", used: serverStatus["cpu"]["usedPercent"].number,
                              total: serverStatus == .null ? 0 : 100,
                              detail: serverStatus == .null ? "" :
                                "Load \(serverStatus["cpu"]["load1"].number.formatted(.number.precision(.fractionLength(2))))")
                machineMetric("RAM", used: serverStatus["memory"]["usedBytes"].number,
                              total: serverStatus["memory"]["totalBytes"].number,
                              detail: byteSummary(serverStatus["memory"]))
                machineMetric("Storage", used: serverStatus["storage"]["usedBytes"].number,
                              total: serverStatus["storage"]["totalBytes"].number,
                              detail: byteSummary(serverStatus["storage"]))
                Divider()
                Button {
                    renewalDraft = renewalTimestamp > 0 ? Date(timeIntervalSince1970: renewalTimestamp) : .now
                    editingRenewal = true
                } label: {
                    HStack {
                        Text("Renewal date")
                        Spacer()
                        Text(renewalTimestamp > 0
                             ? Date(timeIntervalSince1970: renewalTimestamp).formatted(date: .abbreviated, time: .omitted)
                             : "Set date")
                            .foregroundStyle(VesperTheme.muted)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(VesperTheme.muted)
                    }.font(StudioTypography.detail)
                }.buttonStyle(.plain)
                if !serverError.isEmpty {
                    Text(serverError).font(.caption).foregroundStyle(VesperTheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var wakeCard: some View {
        GlassCard(padding: StudioTypography.padding) {
            VStack(alignment: .leading, spacing: StudioTypography.spacing) {
                HStack {
                    Label("Heartbeat", systemImage: "waveform.path.ecg").font(StudioTypography.title)
                    Spacer()
                    NavigationLink { WakeView() } label: {
                        Label("Settings", systemImage: "slider.horizontal.3").font(StudioTypography.detail.weight(.medium))
                            .frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Heartbeat settings")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(!wakeHistoryLoaded ? "—" : (wakeHistoryComplete ? "" : "≥") + String(todayWakes.count))
                        .font(StudioTypography.value).monospacedDigit()
                    Text("wakes today").font(StudioTypography.detail).foregroundStyle(VesperTheme.muted)
                    Spacer()
                    if wake != .null {
                        Text(wake["config"]["enabled"].bool ? "Active" : "Paused")
                            .font(.caption.weight(.medium)).foregroundStyle(VesperTheme.muted)
                    }
                }
                HStack(spacing: 8) {
                    smallMetric("Silent", value: wakeHistoryLoaded ? todayWakes.filter { $0["status"].string == "silent" }.count : nil)
                    smallMetric("Failed", value: wakeHistoryLoaded ? todayWakes.filter { $0["status"].string == "failed" }.count : nil)
                    smallMetric("Tokens", value: wakeHistoryLoaded ? Int(todayWakes.reduce(0) { $0 + $1["tokens"].number }) : nil,
                                compact: true)
                }
                Divider()
                statusRow("This month", value: !wakeHistoryLoaded ? "—" :
                          (wakeHistoryComplete ? "" : "≥") + String(monthWakes.count) + " wakes")
                let tokenJobs = monthWakes.filter { $0["tokens"].number > 0 }
                statusRow("Avg. tokens / wake",
                          value: tokenJobs.isEmpty ? "—" :
                            Int(tokenJobs.reduce(0) { $0 + $1["tokens"].number } / Double(tokenJobs.count))
                                .formatted(.number.notation(.compactName)))
                Divider()
                HStack(spacing: 8) {
                    Text("Next wake").foregroundStyle(VesperTheme.muted)
                    Spacer()
                    if wake["nextAt"].number > 0 && wake["config"]["enabled"].bool {
                        Text(Date(timeIntervalSince1970: wake["nextAt"].number), style: .relative)
                    } else {
                        Text(wake == .null ? "—" : wake["config"]["enabled"].bool ? "Scheduling" : "Paused")
                    }
                    NavigationLink { WakeWorkflowView() } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).frame(width: 24, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel("Wake history")
                }.font(.footnote)
                Divider()
                wakeControls
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var wakeControls: some View {
            VStack(alignment: .leading, spacing: StudioTypography.spacing) {
                Toggle("Automatic wake-up", isOn: Binding(
                    get: { wake["config"]["enabled"].bool },
                    set: { enabled in Task { await updateWake(enabled: enabled) } }
                )).font(.footnote).disabled(wake == .null || updatingRules)
                HStack {
                    Text("Wake frequency").foregroundStyle(VesperTheme.muted)
                    Spacer()
                    Menu {
                        ForEach([0, 30, 45, 60, 90, 120, 180, 240, 360, 720, 1440], id: \.self) { minutes in
                            Button(minutes == 0 ? "Ash decides" :
                                    minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min") {
                                Task { await updateWake(minutes: minutes) }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(wake == .null ? "—" : wakeFrequency)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                    }.disabled(wake == .null || updatingRules)
                }.font(.footnote)
                if !ruleError.isEmpty {
                    Text(ruleError).font(.caption).foregroundStyle(.red)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var wakeFrequency: String {
        guard wake["config"]["enabled"].bool else { return "Paused" }
        let minutes = Int(wake["config"]["intervalMinutes"].number)
        if minutes <= 0 { return "Ash decides" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }
    private func updateWake(enabled: Bool? = nil, minutes: Int? = nil) async {
        guard !updatingRules else { return }
        updatingRules = true
        defer { updatingRules = false }
        do {
            let latest = try await store.api.request("/wake", history: true)
            guard latest["permissionVersion"].number >= 1 else {
                throw ServiceError(message: "Wake controls require a newer VPS service.")
            }
            let interval: JSONValue = minutes.map { $0 == 0 ? .null : .number(Double($0)) }
                ?? latest["config"]["intervalMinutes"]
            let requested: JSONValue = .object([
                "action": .string("configure"),
                "enabled": .bool(enabled ?? latest["config"]["enabled"].bool),
                "intervalMinutes": interval,
                "permissions": latest["permissions"]
            ])
            let result = try await store.api.request("/wake", method: "POST", body: requested, history: true)
            guard result["config"]["enabled"] == requested["enabled"],
                  result["config"]["intervalMinutes"] == interval else {
                throw ServiceError(message: "The VPS did not confirm the change.")
            }
            wake = result
            ruleError = ""
        } catch {
            ruleError = error.localizedDescription
        }
    }
    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(VesperTheme.muted)
            Spacer(minLength: 6)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }.font(.footnote)
    }
    private var managementCard: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                NavigationLink { AgentInstructionsView() } label: {
                    managementRow("Agent Instructions", subtitle: "Shared instructions for your agent", symbol: "doc.text")
                }.accessibilityIdentifier("studio-instructions")
                managementDivider
                NavigationLink { ToolsView() } label: {
                    managementRow("MCP", subtitle: "Connected services and tools", symbol: "square.grid.2x2")
                }.accessibilityIdentifier("studio-mcp")
                managementDivider
                DisclosureGroup {
                    DeviceTokenEditor().padding(.horizontal, 18).padding(.bottom, 16)
                } label: {
                    managementContent("Device token", subtitle: "Access for this device", symbol: "key.horizontal")
                        .padding(.vertical, 14)
                }
                .padding(.horizontal, 18)
                .accessibilityIdentifier("studio-device-token")
            }.buttonStyle(.plain)
        }
    }
    private var managementDivider: some View { Divider().padding(.leading, 62).padding(.trailing, 18) }
    private func managementRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            managementContent(title, subtitle: subtitle, symbol: symbol)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VesperTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
    }
    private func managementContent(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 19)).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(StudioTypography.title)
                Text(subtitle).font(StudioTypography.note).foregroundStyle(VesperTheme.muted)
            }
            Spacer(minLength: 8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(StudioTypography.section)
            .foregroundStyle(VesperTheme.ink).padding(.top, 7).accessibilityAddTraits(.isHeader)
    }
    private func smallMetric(_ title: String, value: Int?, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map { compact ? $0.formatted(.number.notation(.compactName)) : $0.formatted() } ?? "—")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(VesperTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func machineMetric(_ title: String, used: Double, total: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.footnote.weight(.medium))
                Spacer(minLength: 4)
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(VesperTheme.muted).lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(total > 0 ? "\(Int((used / total * 100).rounded()))%" : "—")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: total > 0 ? min(max(used / total, 0), 1) : 0)
                .tint(VesperTheme.accent).opacity(total > 0 ? 1 : 0.3)
        }
    }
    private func byteSummary(_ value: JSONValue) -> String {
        let total = value["totalBytes"].number
        guard total > 0 else { return "" }
        let used = value["usedBytes"].number
        return ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .binary) + " / " +
            ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .binary)
    }
    private func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(Int((Double(count) / 1_000_000).rounded()))m" }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
        return count.formatted()
    }
    private func refreshAll() async {
        async let first: Void = refreshGPT()
        async let second: Void = refreshElevenLabs()
        async let third: Void = refreshActivity()
        async let fourth: Void = refreshServer()
        async let fifth: Void = refreshGateway()
        _ = await (first, second, third, fourth, fifth)
    }
    private func refreshGPT() async {
        await gpt.load(identity: gptIdentity) {
            try await GPTUsageReader.fetch(api: store.api, endpoint: store.socketURL)
        }
    }
    private func refreshElevenLabs() async {
        let key = elevenKey
        await eleven.load(identity: UsageCredentials.fingerprint([key])) {
            guard !key.isEmpty else { throw UsageReadError.unavailable("Connect ElevenLabs in Usage details.") }
            return try await ElevenLabsUsageClient().fetch(apiKey: key)
        }
    }
    private func refreshActivity() async {
        guard !loadingActivity else { return }
        loadingActivity = true; defer { loadingActivity = false }
        let api = store.api
        async let wakeResult: JSONValue? = try? await api.request("/wake", history: true)
        async let historyResult: (jobs: [JSONValue], complete: Bool)? = try? await loadWakeHistory(api: api)
        wake = await wakeResult ?? .null
        if let history = await historyResult {
            wakeJobs = history.jobs; wakeHistoryComplete = history.complete; wakeHistoryLoaded = true
        } else {
            wakeJobs = []; wakeHistoryComplete = false; wakeHistoryLoaded = false
        }
        activityUpdatedAt = (wake == .null && !wakeHistoryLoaded) ? nil : Date()
        activityError = activityUpdatedAt == nil ? "Activity is unavailable. Pull to retry." : ""
    }
    private func refreshServer() async {
        let connection = BackendConnection.load(.vps)
        let token = vpsToken
        guard !token.isEmpty else {
            serverError = serverStatus == .null ? "Connect the VPS to view machine status." : ""
            return
        }
        do {
            let client = APIClient(baseURL: connection.baseURL, historyURL: connection.historyURL, token: token)
            let value = try await client.request("/system-status", history: true)
            guard value["memory"]["totalBytes"].number > 0,
                  value["storage"]["totalBytes"].number > 0 else {
                throw ServiceError(message: "Machine status is unavailable")
            }
            serverStatus = value; serverUpdatedAt = Date(); serverError = ""
        } catch {
            serverError = serverStatus == .null ? "Could not read VPS status." : "Showing the last VPS reading."
        }
    }
    private func refreshGateway() async {
        let token = vpsToken
        guard !token.isEmpty else {
            gatewayStatus = .null
            gatewayError = "Connect the VPS to view gateway status."
            return
        }
        do {
            var components = URLComponents(string: "https://codex.r-vera.com/gateway/health")!
            if let threadID = chat.activeThreadID, !threadID.isEmpty {
                components.queryItems = [URLQueryItem(name: "threadId", value: threadID)]
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = 6
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            let session = URLSession(configuration: config, delegate: UsageRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  value["service"].string == "vesper-gateway",
                  value["upstream"].string == "reachable" else {
                throw UsageReadError.unavailable("Gateway is unavailable.")
            }
            let priorThreshold = gatewayStatus["compaction"]["thresholdTokens"].number
            let nextThreshold = value["compaction"]["thresholdTokens"].number
            if priorThreshold > 0, nextThreshold > 0, priorThreshold != nextThreshold {
                chat.refreshThreadPolicyOnNextSend()
            }
            gatewayStatus = value
            gatewayError = value["routeActive"].bool ? "" : "Gateway is ready; chat routing is inactive."
        } catch {
            gatewayStatus = .null
            gatewayError = "Gateway is unavailable. Pull to retry."
        }
    }
    private func loadWakeHistory(api: APIClient) async throws -> (jobs: [JSONValue], complete: Bool) {
        var jobs: [JSONValue] = []
        var offset = 0
        for _ in 0..<20 {
            let page = try await api.request("/wake?view=workflow&limit=50&offset=\(offset)", history: true)
            jobs += page["jobs"].array
            if jobs.last.map({ $0["created"].number < monthStart }) == true { return (jobs, true) }
            guard case .number(let next) = page["nextOffset"] else { return (jobs, true) }
            offset = Int(next)
        }
        return (jobs, false)
    }
}
