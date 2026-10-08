import SwiftUI

enum TerminalRecordedHistory {
    static func merge(_ existing: [JSONValue], _ incoming: [JSONValue]) -> [JSONValue] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for item in incoming { byID[item.id] = item }
        return byID.values.sorted { ($0["createdAt"].string, $0.id) < ($1["createdAt"].string, $1.id) }
    }
    static func text(_ records: [JSONValue], live: String) -> String {
        let history = records.map { item -> String in
            switch item["type"].string {
            case "UserMessage": return "> " + item["text"].string
            case "AgentMessage": return "• " + item["text"].string + (item["textTruncated"].bool ? "\n[Long text truncated in terminal history]" : "")
            case "CommandExecution": return "$ " + item["title"].string + "\n" + item["output"].string
            case "FileChange": return "File changes · " + item["status"].string + "\n" + item["output"].string
            default: return "Called " + item["title"].string + " · " + item["status"].string
            }
        }.joined(separator: "\n\n")
        return (history.isEmpty ? "" : "Recorded Codex activity\n\n" + history + "\n\n—— Live terminal ——\n\n") + live
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
    @State private var records: [JSONValue] = []
    @State private var before = ""
    @State private var hasMore = false
    @State private var loadingHistory = false
    @State private var columns = 48
    @State private var resizeSupported = false
    @State private var resizeRejected = false
    @State private var displaySelected = true
    private var showingDisplay: Bool { store.activeBackend == .vps && displaySelected }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if store.activeBackend == .vps {
                    Picker("VPS view", selection: $displaySelected) {
                        Text("画面").tag(true)
                        Text("终端").tag(false)
                    }.pickerStyle(.segmented).accessibilityIdentifier("vps-monitor-tabs")
                }
                if showingDisplay {
                    VPSBrowserDisplay(api: store.api)
                } else {
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(connected ? (running ? "Live · This chat" : "No active terminal") : "Disconnected")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Button { retry += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reconnect terminal")
                }
                if hasMore {
                    Button(loadingHistory ? "Loading…" : "Load earlier terminal activity") {
                        Task { await loadOlder() }
                    }.font(.caption).disabled(loadingHistory)
                }
                GeometryReader { size in
                    TerminalTextViewport(text: TerminalRecordedHistory.text(records, live: screen.isEmpty ? "Open the terminal for this chat to continue it." : screen))
                        .task(id: Int(size.size.width)) {
                            columns = TerminalTextViewport.columns(for: size.size.width)
                            if running { await resize() }
                        }
                }
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if connected && !running {
                    Button("Open this chat in terminal") { perform(endpoint + "/start") }
                        .buttonStyle(.bordered).disabled(busy)
                }
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
                Text("Persistent VPS session · closing this window keeps it running")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
                }
            }.padding(16).background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .navigationTitle(store.activeBackend == .vps ? "VPS" : "Chat terminal").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(.white) } }
        }.preferredColorScheme(.dark).tint(.white).foregroundStyle(.white)
            .task(id: "\(scenePhase)-\(retry)-\(showingDisplay)-\(store.activeBackend.rawValue)") {
                guard scenePhase == .active, !showingDisplay else { connected = false; return }
                await followScreen()
            }
    }

    private func followScreen() async {
        connected = false; resizeRejected = false; records = []; before = ""; hasMore = false
        while !Task.isCancelled {
            do {
                let result = try await store.api.request(endpoint, history: true)
                try Task.checkCancellation()
                guard result["conversationId"].string == conversationID else { throw ServiceError(message: "The server returned a terminal for another chat.") }
                screen = result["screen"].string
                records = TerminalRecordedHistory.merge(records, result["history"]["records"].array)
                if before.isEmpty { before = result["history"]["before"].string; hasMore = result["history"]["hasMore"].bool }
                if !result["historyError"].string.isEmpty { error = result["historyError"].string }
                let wasRunning = running, wasResizable = resizeSupported
                running = result["running"].bool
                resizeSupported = result["capabilities"]["resize"].bool && !resizeRejected
                if running && (!wasRunning || !wasResizable) { await resize() }
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
        guard resizeSupported else { return }
        do { _ = try await store.api.request(endpoint + "/resize", method: "POST", body: .object(["columns": .number(Double(columns))]), history: true) }
        catch is CancellationError { }
        catch let failure as ServiceError where failure.statusCode == 405 {
            resizeRejected = true; resizeSupported = false
        }
        catch { self.error = "Terminal resize failed: " + error.localizedDescription }
    }
    private func loadOlder() async {
        guard !loadingHistory, !before.isEmpty else { return }
        loadingHistory = true; defer { loadingHistory = false }
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "before", value: before)]
            let result = try await store.api.request(endpoint + "?" + (query.percentEncodedQuery ?? ""), history: true)
            try Task.checkCancellation()
            guard result["conversationId"].string == conversationID else { throw ServiceError(message: "The server returned a terminal for another chat.") }
            if !result["historyError"].string.isEmpty { throw ServiceError(message: result["historyError"].string) }
            records = TerminalRecordedHistory.merge(records, result["history"]["records"].array)
            before = result["history"]["before"].string; hasMore = result["history"]["hasMore"].bool
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

enum VPSDisplaySource {
    static func client(_ api: APIClient, session: URLSession? = nil) throws -> APIClient {
        guard var origin = URLComponents(string: api.historyURL), origin.scheme == "https",
              origin.host != nil, origin.user == nil, origin.password == nil,
              origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "history" else {
            throw ServiceError(message: "This connection does not provide a VPS display address.")
        }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        guard let address = origin.url?.absoluteString else { throw ServiceError(message: "Invalid VPS display address.") }
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
        return APIClient(baseURL: address, historyURL: address, token: api.token,
            requestSession: session ?? URLSession(configuration: config, delegate: VPSDisplayRedirectPolicy(), delegateQueue: nil))
    }
}

private final class VPSDisplayRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct VPSDisplayFrame {
    let state: String
    let title: String
    let url: String
    let busy: Bool
    let capturedAt: String
    let data: Data?
    init(_ value: JSONValue) throws {
        guard value["kind"].string == "browser", ["live", "working", "idle", "owner_login", "private", "unavailable"].contains(value["state"].string) else {
            throw ServiceError(message: "The VPS returned an invalid display status.")
        }
        state = value["state"].string; title = value["title"].string; url = value["url"].string
        busy = value["busy"].bool; capturedAt = value["capturedAt"].string
        let encoded = value["image"].string
        if encoded.isEmpty { data = nil }
        else {
            guard value["mimeType"].string == "image/jpeg", encoded.utf8.count <= 700_000,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 512 * 1024, UIImage(data: bytes) != nil,
                  !capturedAt.isEmpty else { throw ServiceError(message: "The VPS returned an invalid browser frame.") }
            data = bytes
        }
        if state == "live", data == nil { throw ServiceError(message: "The VPS did not return the live browser frame.") }
    }
    var label: String {
        switch state {
        case "live": return busy ? "浏览器正在操作" : "实时浏览器画面"
        case "working": return "浏览器正在更新"
        case "idle": return "当前没有打开的网页"
        case "owner_login": return "浏览器正在由你维护登录"
        case "private": return "当前网页含敏感会话信息"
        default: return "暂时无法取得画面"
        }
    }
}

struct VPSBrowserDisplay: View {
    let api: APIClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var frame: VPSDisplayFrame?
    @State private var connected = false
    @State private var error = ""
    @State private var retry = 0
    private var taskID: String { "\(scenePhase)-\(retry)-\(api.historyURL)-\(api.token.hashValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(connected ? (frame?.label ?? "连接中…") : (error.isEmpty ? "连接中…" : "连接中断"))
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button { retry += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("重新连接 VPS 画面")
            }
            if let frame, !frame.title.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(frame.title).font(.subheadline).lineLimit(2)
                    Text(frame.url).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
            }
            if let data = frame?.data, let image = UIImage(data: data) {
                VPSFrameViewport(image: image).accessibilityLabel("VPS 当前网页画面，可双指缩放")
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display").font(.system(size: 36)).foregroundStyle(.white.opacity(0.45))
                    Text(frame?.label ?? "正在连接 VPS…").font(.subheadline)
                    if frame?.state == "idle" { Text("Rowan 打开网页时，画面会自动出现在这里。").font(.caption).foregroundStyle(.white.opacity(0.65)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let captured = frame?.capturedAt, !captured.isEmpty {
                Text((connected ? "画面更新于 " : "最后画面 · ") + displayTime(captured))
                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("VPS 浏览器 · 双指缩放 · 仅查看").font(.caption2).foregroundStyle(.white.opacity(0.65))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: taskID) { await follow() }
    }
    private func displayTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .omitted, time: .standard)
    }
    private func follow() async {
        connected = false; frame = nil; error = ""
        guard scenePhase == .active else { return }
        do {
            let client = try VPSDisplaySource.client(api)
            defer { client.requestSession.invalidateAndCancel() }
            while !Task.isCancelled {
                do {
                    let value = try await client.request("/browser/display", history: true)
                    try Task.checkCancellation()
                    frame = try VPSDisplayFrame(value); connected = true; error = ""
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    connected = false; self.error = error.localizedDescription
                    // Retry only read-only frames, with backoff; never submit a model/tool turn.
                    try await Task.sleep(for: .seconds(5))
                }
                try await Task.sleep(for: .milliseconds(1500))
            }
        } catch is CancellationError { }
        catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription }
    }
}

struct VPSFrameViewport: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> VPSZoomScrollView {
        let view = VPSZoomScrollView(); view.delegate = context.coordinator
        view.backgroundColor = UIColor(white: 0.04, alpha: 1); view.addSubview(view.picture)
        context.coordinator.picture = view.picture
        view.maximumZoomScale = 4; view.bouncesZoom = true
        return view
    }
    func updateUIView(_ view: VPSZoomScrollView, context: Context) {
        if view.picture.image?.size != image.size {
            view.setZoomScale(1, animated: false); view.picture.frame = CGRect(origin: .zero, size: image.size)
            view.contentSize = image.size; view.resetFit = true
        }
        view.picture.image = image; view.setNeedsLayout()
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var picture: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    }
}

final class VPSZoomScrollView: UIScrollView {
    let picture = UIImageView()
    var resetFit = true
    private var lastBounds = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = picture.image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        if resetFit || lastBounds != bounds.size {
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            minimumZoomScale = fit; setZoomScale(fit, animated: false)
            resetFit = false; lastBounds = bounds.size
        }
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - picture.frame.height) / 2), left: max(0, (bounds.width - picture.frame.width) / 2), bottom: 0, right: 0)
    }
}
