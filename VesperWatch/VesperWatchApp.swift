import SwiftUI
import WatchConnectivity
import Security
import WidgetKit
import ImageIO

struct WatchRoom: Decodable, Identifiable {
    let id: String
    let title: String
}

struct WatchMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String
    let status: String?
    let metadata: Metadata?

    struct Metadata: Decodable {
        let originDevice: String?
        let source: String?
        let companionPokeId: String?
        let watchMessage: Bool?
    }

    var originDevice: String? {
        guard role == "user" else { return nil }
        if let value = metadata?.originDevice,
           ["iPhone", "iPad", "Mac", "Apple Watch"].contains(value) { return value }
        if metadata?.source == "watch" { return "Apple Watch" }
        if metadata?.source == "lockscreen" { return "iPhone" }
        return nil
    }

    func displayText(agentName: String) -> String {
        if role == "user", metadata?.companionPokeId != nil,
           metadata?.watchMessage != true, let originDevice {
            return "我拍了拍“\(agentName)” · \(originDevice)"
        }
        return content
    }
}

private struct RoomList: Decodable { let conversations: [WatchRoom] }
private struct RoomHistory: Decodable { let messages: [WatchMessage] }

private enum WatchToken {
    static let account = "vps-device-token"
    static let service = "com.vera.vesper.watch"

    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

@MainActor final class WatchChat: NSObject, ObservableObject, WCSessionDelegate {
    @Published var agentName = "Vesper"
    @Published var rooms: [WatchRoom] = []
    @Published var messages: [WatchMessage] = []
    @Published var busy = false
    @Published var error: String?
    @Published var isConfigured = false
    @Published var selectedRoom = ""
    @Published var avatarData = UserDefaults.standard.data(forKey: "avatarData")
    @Published var glassStyle = UserDefaults.standard.string(forKey: "glassStyle") ?? "liquid"
    @Published var glassFrost = UserDefaults.standard.bool(forKey: "glassFrost")
    @Published var glassTransparency = UserDefaults.standard.double(forKey: "glassTransparency")
    @Published var reduceTransparency = UserDefaults.standard.bool(forKey: "reduceTransparency")

    private var historyURL = UserDefaults.standard.string(forKey: "historyURL") ?? "https://codex.r-vera.com/history"
    private var token = WatchToken.load()
    private var userName = UserDefaults.standard.string(forKey: "userName") ?? "Vera"
    private var instructions = UserDefaults.standard.string(forKey: "instructions") ?? ""
    private var greeting = UserDefaults.standard.string(forKey: "greeting") ?? "Come as you are."
    private var profileUpdatedAt = UserDefaults.standard.double(forKey: "profileUpdatedAt")
    private let session = WCSession.default

    override init() {
        super.init()
        isConfigured = !token.isEmpty
        agentName = UserDefaults.standard.string(forKey: "agentName") ?? "Vesper"
        selectedRoom = UserDefaults.standard.string(forKey: "conversationId") ?? ""
        publishWidgetSettings()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
            if !session.receivedApplicationContext.isEmpty {
                apply(session.receivedApplicationContext)
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.apply(context)
            self.requestLatestProfile()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.requestLatestProfile() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    func synchronizeProfile() { requestLatestProfile() }

    private func requestLatestProfile() {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["request": "profile"], replyHandler: { context in
            Task { @MainActor in self.apply(context) }
        }, errorHandler: { _ in })
    }

    private func apply(_ context: [String: Any]) {
        guard let newToken = context["token"] as? String, !newToken.isEmpty else { return }
        let updatedAt = context["updatedAt"] as? Double ?? 0
        guard updatedAt == 0 || updatedAt >= profileUpdatedAt else { return }
        if updatedAt > 0 {
            profileUpdatedAt = updatedAt
            UserDefaults.standard.set(updatedAt, forKey: "profileUpdatedAt")
        }
        token = newToken
        WatchToken.save(newToken)
        historyURL = context["historyURL"] as? String ?? historyURL
        agentName = context["agentName"] as? String ?? agentName
        userName = context["userName"] as? String ?? userName
        instructions = context["instructions"] as? String ?? instructions
        greeting = context["greeting"] as? String ?? greeting
        if let data = context["avatarData"] as? Data { avatarData = data }
        else if context["avatarAvailable"] as? Bool == false { avatarData = nil }
        glassStyle = context["glassStyle"] as? String ?? glassStyle
        glassFrost = context["glassFrost"] as? Bool ?? glassFrost
        glassTransparency = min(1, max(0, context["glassTransparency"] as? Double ?? glassTransparency))
        reduceTransparency = context["reduceTransparency"] as? Bool ?? reduceTransparency
        if let main = context["conversationId"] as? String, !main.isEmpty { selectedRoom = main }
        UserDefaults.standard.set(historyURL, forKey: "historyURL")
        UserDefaults.standard.set(agentName, forKey: "agentName")
        UserDefaults.standard.set(userName, forKey: "userName")
        UserDefaults.standard.set(instructions, forKey: "instructions")
        UserDefaults.standard.set(greeting, forKey: "greeting")
        UserDefaults.standard.set(glassStyle, forKey: "glassStyle")
        UserDefaults.standard.set(glassFrost, forKey: "glassFrost")
        UserDefaults.standard.set(glassTransparency, forKey: "glassTransparency")
        UserDefaults.standard.set(reduceTransparency, forKey: "reduceTransparency")
        if let avatarData {
            UserDefaults.standard.set(avatarData, forKey: "avatarData")
        } else {
            UserDefaults.standard.removeObject(forKey: "avatarData")
        }
        UserDefaults.standard.set(selectedRoom, forKey: "conversationId")
        isConfigured = true
        publishWidgetSettings()
        Task { await refresh() }
    }

    private func publishWidgetSettings() {
        guard !token.isEmpty else { return }
        WatchWidgetSettings.update(token: token, historyURL: historyURL,
                                   conversationID: selectedRoom, agentName: agentName,
                                   userName: userName, instructions: instructions,
                                   greeting: greeting, avatarData: avatarData)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        guard let base = URL(string: historyURL + (historyURL.hasSuffix("/") ? "" : "/")),
              base.scheme == "https", !token.isEmpty,
              let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Vesper Watch", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "聊天暂时无法同步，请稍后重试。"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func refresh() async {
        guard isConfigured, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let list: RoomList = try await request("conversations")
            rooms = list.conversations
            if !rooms.contains(where: { $0.id == selectedRoom }) {
                selectedRoom = rooms.first?.id ?? ""
                UserDefaults.standard.set(selectedRoom, forKey: "conversationId")
                publishWidgetSettings()
            }
            try await loadMessages()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadMessages() async throws {
        guard !selectedRoom.isEmpty else { messages = []; return }
        let safeID = selectedRoom.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedRoom
        let page: RoomHistory = try await request("conversations/\(safeID)?latest=1&limit=40")
        messages = page.messages.filter { ($0.role == "user" || $0.role == "agent") && !$0.content.isEmpty && $0.status != "streaming" }
    }

    func select(_ room: WatchRoom) async {
        selectedRoom = room.id
        UserDefaults.standard.set(room.id, forKey: "conversationId")
        publishWidgetSettings()
        do { try await loadMessages(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedRoom.isEmpty, !trimmed.isEmpty, !busy else { return false }
        guard trimmed.count <= 2000 else { error = "手表消息最多 2000 字。"; return false }
        return await submit(path: "companion/watch-message", text: trimmed)
    }

    func poke() async {
        guard !selectedRoom.isEmpty, !busy else { return }
        _ = await submit(path: "companion/poke", text: nil)
    }

    private func submit(path: String, text: String?) async -> Bool {
        busy = true
        defer { busy = false }
        var body = ["requestId": UUID().uuidString, "conversationId": selectedRoom,
                    "name": agentName, "userName": userName, "instructions": instructions,
                    "originDevice": "Apple Watch"]
        if let text { body["text"] = text } else { body["origin"] = "watch" }
        do {
            let previousReplyID = messages.last(where: { $0.role == "agent" })?.id
            let _: WatchReceipt = try await request(path, method: "POST", body: body)
            error = nil
            for _ in 0..<40 {
                try await loadMessages()
                if let last = messages.last(where: { $0.role == "agent" }), last.id != previousReplyID { return true }
                try await Task.sleep(for: .seconds(3))
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

private struct WatchReceipt: Decodable { let requestId: String }

@main struct VesperWatchApp: App {
    @StateObject private var chat = WatchChat()
    var body: some Scene {
        WindowGroup { WatchHome().environmentObject(chat) }
    }
}

private struct WatchHome: View {
    @EnvironmentObject private var chat: WatchChat
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            if !chat.isConfigured {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    Text("请先在 iPhone 打开 Vesper")
                        .multilineTextAlignment(.center)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            WatchContactAvatar(data: chat.avatarData, name: chat.agentName)
                            Text(chat.agentName).font(.headline).lineLimit(1)
                        }
                        if chat.rooms.count > 1 {
                            Picker("聊天", selection: $chat.selectedRoom) {
                                ForEach(chat.rooms) { room in
                                    Text(room.title).tag(room.id)
                                }
                            }
                            .onChange(of: chat.selectedRoom) { _, newValue in
                                if let room = chat.rooms.first(where: { $0.id == newValue }) {
                                    Task { await chat.select(room) }
                                }
                            }
                        }
                        ForEach(chat.messages.suffix(12)) { message in
                            WatchBubble(message: message, agentName: chat.agentName,
                                        glassStyle: chat.glassStyle, glassFrost: chat.glassFrost,
                                        glassTransparency: chat.glassTransparency,
                                        reduceTransparency: chat.reduceTransparency)
                        }
                        if let error = chat.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                        TextField("输入或语音听写", text: $draft, axis: .vertical)
                            .submitLabel(.send)
                            .onSubmit { send() }
                        HStack {
                            Button { send() } label: { Label("发送", systemImage: "arrow.up") }
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.selectedRoom.isEmpty || chat.busy)
                            Button { Task { await chat.poke() } } label: { Label("拍一拍", systemImage: "hand.tap") }
                                .disabled(chat.selectedRoom.isEmpty || chat.busy)
                        }
                        Button { chat.synchronizeProfile(); Task { await chat.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            .disabled(chat.busy)
                    }
                }
                .task { chat.synchronizeProfile(); await chat.refresh() }
            }
        }
        .navigationTitle(chat.agentName)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { chat.synchronizeProfile(); Task { await chat.refresh() } }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { if !(await chat.send(text)) { draft = text } }
    }
}

private struct WatchContactAvatar: View {
    let data: Data?
    let name: String
    var body: some View {
        Group {
            if let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1))).font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.16))
            }
        }.frame(width: 36, height: 36).clipShape(Circle()).accessibilityHidden(true)
    }
}

private struct WatchBubble: View {
    let message: WatchMessage
    let agentName: String
    let glassStyle: String
    let glassFrost: Bool
    let glassTransparency: Double
    let reduceTransparency: Bool
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10) }
    var body: some View {
        Text(message.displayText(agentName: agentName))
            .font(.system(size: 13))
            .padding(8)
            .background(message.role == "user" ? Color.blue.opacity(0.14) : Color.clear, in: shape)
            .background { surface }
            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency || systemReduceTransparency {
            shape.fill(Color(white: 0.15))
        } else if glassStyle == "liquid" {
            #if compiler(>=6.2)
            if #available(watchOS 26.0, *) {
                let glass: Glass = glassFrost ? .regular : .clear
                shape.fill(.clear).glassEffect(glass, in: shape)
            } else { classicSurface }
            #else
            classicSurface
            #endif
        } else { classicSurface }
    }

    private var classicSurface: some View {
        let opacity = 1 - min(1, max(0, glassTransparency))
        return shape.fill(.ultraThinMaterial)
            .overlay(shape.stroke(.white.opacity(0.55), lineWidth: 0.6))
            .opacity(opacity)
    }
}
