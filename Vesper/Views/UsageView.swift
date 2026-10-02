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
        Page(title: "Usage", subtitle: "Your account limits and voice balance.") {
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
                    Label("中国站账单", systemImage: "arrow.up.right.square")
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
            Page(title: "ElevenLabs access") {
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Use a key with subscription read permission. It is stored in this device’s Keychain and sent only to ElevenLabs.")
                            .font(.subheadline)
                        SecureField("ElevenLabs API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(12).background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 12))
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
