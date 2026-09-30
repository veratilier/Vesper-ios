import SwiftUI

enum ChatTerminalHistory {
    static func path(_ conversation: String, before: String) -> String {
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "latest", value: "1"), URLQueryItem(name: "limit", value: "60")]
        if !before.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: before)) }
        return "/conversations/\(conversation)?" + (query.percentEncodedQuery ?? "")
    }
    static func merge(_ existing: [JSONValue], _ incoming: [JSONValue]) -> [JSONValue] {
        var seen = Set<String>()
        return ChatTranscript.ordered(existing + incoming).filter { !ChatPresentation.isActivity($0) && seen.insert($0.id).inserted }
    }
}

struct TerminalTextViewport: UIViewRepresentable {
    let text: String
    static func columns(for width: CGFloat) -> Int {
        let cell = ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
        return min(120, max(24, Int(max(1, width - 8) / cell)))
    }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear; view.textColor = .white
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        view.textContainer.lineFragmentPadding = 0; view.textContainer.widthTracksTextView = true
        view.textContainer.lineBreakMode = .byCharWrapping
        view.alwaysBounceHorizontal = false; view.showsHorizontalScrollIndicator = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let offset = view.contentOffset
        let nearBottom = view.text.isEmpty || offset.y + view.bounds.height >= view.contentSize.height - 48
        view.text = text; view.layoutIfNeeded()
        if nearBottom { view.setContentOffset(CGPoint(x: 0, y: max(0, view.contentSize.height - view.bounds.height)), animated: false) }
        else { view.setContentOffset(CGPoint(x: 0, y: min(offset.y, max(0, view.contentSize.height - view.bounds.height))), animated: false) }
    }
}

struct ChatTerminalView: View {
    let conversationID: String
    private var endpoint: String { "/conversations/\(conversationID)/terminal" }
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = ""
    @State private var draft = ""
    @State private var error = ""
    @State private var connected = false
    @State private var running = false
    @State private var busy = false
    @State private var retry = 0
    @State private var mode = 0
    @State private var records: [JSONValue] = []
    @State private var before = ""
    @State private var hasMore = false
    @State private var loadingHistory = false
    @State private var columns = 48

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(connected ? (running ? "Live · This chat" : "No active terminal") : "Disconnected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { retry += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reconnect terminal")
                }
                Picker("Terminal view", selection: $mode) { Text("Live terminal").tag(0); Text("Chat history").tag(1) }.pickerStyle(.segmented)
                if mode == 0 {
                    GeometryReader { size in
                        TerminalTextViewport(text: screen.isEmpty ? "Open the terminal for this chat to continue it. Older messages are in Chat history." : screen)
                            .task(id: Int(size.size.width)) {
                                columns = TerminalTextViewport.columns(for: size.size.width)
                                if running { await resize() }
                            }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if hasMore { Button(loadingHistory ? "Loading…" : "Load older messages") { Task { await loadHistory(reset: false) } }.disabled(loadingHistory) }
                            ForEach(records) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text((ChatPresentation.isUser(message) ? "Vera" : "Rowan") + " · " + ChatPresentation.time(message["createdAt"].string, full: true))
                                        .font(.caption).foregroundStyle(.secondary)
                                    ChatMarkdownText(content: message["content"].string).font(.system(size: 14))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if records.isEmpty && !loadingHistory { Text("No saved messages in this chat.").font(.caption) }
                            if loadingHistory { ProgressView() }
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if mode == 0 && connected && !running {
                    Button("Open this chat in terminal") { perform(endpoint + "/start") }
                        .buttonStyle(.bordered).disabled(busy)
                }
                if mode == 0 {
                HStack(spacing: 8) {
                    ForEach(["Esc", "Tab", "^C", "←", "↑", "↓", "→", "↵"], id: \.self) { label in
                        Button(label) { sendKey(label) }
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.disabled(!connected || !running || busy)
                HStack {
                    TextField("Type into VPS terminal…", text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { sendDraft() }
                    Button { sendDraft() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .accessibilityLabel("Send to terminal")
                        .disabled(draft.isEmpty || !connected || !running || busy)
                }.padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                Text(mode == 0 ? "Persistent VPS session · closing this window keeps it running" : "Saved messages for this chat · load older messages above")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16).background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .navigationTitle("Chat terminal").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(.white)
            .task(id: "\(scenePhase)-\(retry)-\(mode)") {
                guard scenePhase == .active else { connected = false; return }
                if mode == 0 { await followScreen() } else { await loadHistory(reset: true) }
            }
    }

    private func followScreen() async {
        connected = false
        while !Task.isCancelled {
            do {
                let result = try await store.api.request(endpoint, history: true)
                try Task.checkCancellation()
                guard result["conversationId"].string == conversationID else { throw ServiceError(message: "The server returned a terminal for another chat.") }
                screen = result["screen"].string
                let wasRunning = running
                running = result["running"].bool
                if running && !wasRunning { await resize() }
                connected = true
                // A failed input is not automatically retried or erased by polling.
                try await Task.sleep(for: .milliseconds(500))
            } catch is CancellationError { return }
            catch let failure {
                guard !Task.isCancelled else { return }
                connected = false
                error = failure.localizedDescription
                return
            }
        }
    }

    private func resize() async {
        do { _ = try await store.api.request(endpoint + "/resize", method: "POST", body: .object(["columns": .number(Double(columns))]), history: true) }
        catch { self.error = error.localizedDescription }
    }
    private func loadHistory(reset: Bool) async {
        guard !loadingHistory else { return }; loadingHistory = true; defer { loadingHistory = false }
        do {
            let result = try await store.api.request(ChatTerminalHistory.path(conversationID, before: reset ? "" : before), history: true)
            try Task.checkCancellation()
            records = ChatTerminalHistory.merge(reset ? [] : records, result["messages"].array)
            before = result["before"].string; hasMore = result["hasMore"].bool; error = ""
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func sendKey(_ label: String) {
        let keys = ["Esc": "Escape", "Tab": "Tab", "^C": "C-c", "←": "Left",
                    "↑": "Up", "↓": "Down", "→": "Right", "↵": "Enter"]
        if let key = keys[label] { perform(endpoint + "/input", body: .object(["key": .string(key)])) }
    }

    private func sendDraft() {
        guard !draft.isEmpty, connected, running, !busy else { return }
        perform(endpoint + "/input", body: .object(["text": .string(draft)]), sentDraft: draft)
    }

    private func perform(_ path: String, body: JSONValue? = nil, sentDraft: String? = nil) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await store.api.request(path, method: "POST", body: body, history: true)
                error = ""
                if let sentDraft, draft == sentDraft { draft = "" }
                retry += 1
            } catch let failure {
                error = "Not confirmed. Check the live screen before sending again. " + failure.localizedDescription
            }
        }
    }
}
