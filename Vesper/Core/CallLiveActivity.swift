#if targetEnvironment(macCatalyst)
import Foundation
// macOS shows the in-app call; Live Activities belong to the iPhone target.
@MainActor final class CallLiveActivity {
    static let shared = CallLiveActivity()
    func start(at date: Date, isVideo: Bool, avatar: String, baseURL: String, name: String, backend: VesperBackend) {}
    func update(isVideo: Bool) {}
    func updateName(_ name: String, backend: VesperBackend) {}
    func updateControls(muted: Bool, speakerEnabled: Bool) {}
    func end() {}
    func endStale() async {}
}
#else
import ActivityKit
import Foundation
import UIKit

@MainActor final class CallLiveActivity {
    static let shared = CallLiveActivity()
    private var activity: Activity<VesperCallAttributes>?
    private var contactName = "Rowan"
    private var backend: VesperBackend?
    private var isVideo = false
    private var muted = false
    private var speakerEnabled = false
    private var avatarTask: Task<Void, Never>?
    private let sharedDefaults = UserDefaults(suiteName: "group.com.vera.vesper.native")

    func start(at date: Date, isVideo: Bool, avatar: String, baseURL: String, name: String, backend: VesperBackend) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        avatarTask?.cancel(); avatarTask = nil
        self.isVideo = isVideo
        self.contactName = name; self.backend = backend
        muted = InAppCalls.shared.muted
        speakerEnabled = InAppCalls.shared.speakerEnabled
        if avatar.hasPrefix("data:image/"), let comma = avatar.firstIndex(of: ","),
           let data = Data(base64Encoded: String(avatar[avatar.index(after: comma)...])) {
            saveAvatar(data)
        } else {
            sharedDefaults?.removeObject(forKey: "activeCallAvatar")
        }
        // A previous process may have left a stale island behind after a crash.
        let stale = Activity<VesperCallAttributes>.activities
        Task { for item in stale { await item.end(nil, dismissalPolicy: .immediate) } }
        do {
            let current = try Activity.request(
                attributes: VesperCallAttributes(startedAt: date),
                content: ActivityContent(state: .init(isVideo: isVideo, muted: muted,
                                                     speakerEnabled: speakerEnabled, name: contactName), staleDate: nil),
                pushType: nil
            )
            activity = current
            if !avatar.isEmpty, !avatar.hasPrefix("data:"),
               let url = URL(string: avatar, relativeTo: URL(string: baseURL))?.absoluteURL,
               url.scheme == "https" {
                avatarTask = Task { [weak self] in
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        try Task.checkCancellation()
                        guard let self, self.activity?.id == current.id,
                              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return }
                        self.saveAvatar(data)
                        var state = current.content.state
                        state.avatarRevision += 1
                        await current.update(ActivityContent(state: state, staleDate: nil))
                    } catch { /* Keep the name fallback if the portrait is unavailable. */ }
                }
            }
        } catch {
            // The in-app call remains usable if Live Activities are disabled.
            activity = nil
            sharedDefaults?.removeObject(forKey: "activeCallAvatar")
        }
    }

    func updateName(_ name: String, backend: VesperBackend) {
        guard self.backend == backend, name != contactName else { return }
        contactName = name
        updateContent()
    }

    func update(isVideo: Bool) {
        self.isVideo = isVideo
        updateContent()
    }

    func updateControls(muted: Bool, speakerEnabled: Bool) {
        self.muted = muted
        self.speakerEnabled = speakerEnabled
        updateContent()
    }

    private func updateContent() {
        guard let activity else { return }
        let state = VesperCallAttributes.ContentState(isVideo: isVideo, muted: muted,
                                                      speakerEnabled: speakerEnabled,
                                                      avatarRevision: activity.content.state.avatarRevision,
                                                      name: contactName)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        avatarTask?.cancel(); avatarTask = nil
        let current = activity
        activity = nil
        sharedDefaults?.removeObject(forKey: "activeCallAvatar")
        if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
    }

    func endStale() async {
        guard activity == nil else { return }
        avatarTask?.cancel(); avatarTask = nil
        sharedDefaults?.removeObject(forKey: "activeCallAvatar")
        let stale = Activity<VesperCallAttributes>.activities
        for item in stale {
            guard item.id != activity?.id else { continue }
            await item.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func saveAvatar(_ data: Data) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { _ in
            let scale = max(96 / image.size.width, 96 / image.size.height)
            image.draw(in: CGRect(x: (96 - image.size.width * scale) / 2,
                                  y: (96 - image.size.height * scale) / 2,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        sharedDefaults?.set(thumbnail.pngData(), forKey: "activeCallAvatar")
    }
}

@MainActor enum LegacyChatTaskActivityCleanup {
    static func endAll() async {
        for activity in Activity<VesperChatTaskAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#endif

#if !targetEnvironment(macCatalyst)
import Combine
import UIKit

@MainActor final class CompanionLiveActivity: ObservableObject {
    static let shared = CompanionLiveActivity()
    @Published private(set) var isActive = false
    @Published private(set) var working = false
    @Published private(set) var error: String?
    private var activity: Activity<VesperCompanionAttributes>?
    private var stateTask: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    private let sharedDefaults = UserDefaults(suiteName: "group.com.vera.vesper.native")

    /// Recover the system activity when the app returns, without starting a new one.
    func refresh() {
        // Retire screen-request activities left by older builds of the app.
        for old in Activity<VesperCompanionAttributes>.activities
            where old.attributes.avatarKey.hasPrefix("companionAvatar-screen-") {
            sharedDefaults?.removeObject(forKey: old.attributes.avatarKey)
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let current = Activity<VesperCompanionAttributes>.activities.first {
            !$0.attributes.avatarKey.hasPrefix("companionAvatar-screen-") &&
            ($0.activityState == .active || $0.activityState == .stale)
        }
        isActive = current != nil
        guard activity?.id != current?.id else { return }
        activity = current
        stateTask?.cancel()
        guard let current else { return }
        stateTask = Task { [weak self] in
            for await state in current.activityStateUpdates {
                guard !Task.isCancelled, let self, self.activity?.id == current.id else { return }
                if state == .ended || state == .dismissed {
                    self.sharedDefaults?.removeObject(forKey: current.attributes.avatarKey)
                    self.avatarTask?.cancel()
                    self.activity = nil; self.isActive = false
                    return
                }
            }
        }
    }

    func start(avatar: String, baseURL: String, name: String, backend: VesperBackend) {
        refresh(); error = nil
        guard !isActive, !working else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            error = "请在系统设置 → Vesper 中允许实时活动。"
            return
        }
        // Remove only expired companion portraits, never call portraits or other widget data.
        let existingKeys = Set(Activity<VesperCompanionAttributes>.activities.map { $0.attributes.avatarKey })
        for key in sharedDefaults?.dictionaryRepresentation().keys ?? Dictionary<String, Any>().keys
            where key.hasPrefix("companionAvatar-") && !existingKeys.contains(key) {
            sharedDefaults?.removeObject(forKey: key)
        }
        let key = "companionAvatar-" + UUID().uuidString
        if avatar.hasPrefix("data:image/"), let comma = avatar.firstIndex(of: ","),
           let data = Data(base64Encoded: String(avatar[avatar.index(after: comma)...])) {
            saveAvatar(data, key: key)
        }
        do {
            let current = try Activity.request(
                attributes: VesperCompanionAttributes(startedAt: .now, avatarKey: key, backend: backend.rawValue),
                content: ActivityContent(state: .init(name: name, greeting: ChatWelcomeLines.next(after: sharedDefaults?.string(forKey: "companionGreeting") ?? "")), staleDate: nil, relevanceScore: 0),
                pushType: nil)
            sharedDefaults?.set(current.content.state.greeting, forKey: "companionGreeting")
            if backend == .vps { WatchSyncBridge.shared.publishGreeting(current.content.state.greeting ?? "") }
            refresh()
            if !avatar.isEmpty, !avatar.hasPrefix("data:"),
               let url = URL(string: avatar, relativeTo: URL(string: baseURL))?.absoluteURL,
               url.scheme == "https" {
                avatarTask?.cancel()
                avatarTask = Task { [weak self] in
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        try Task.checkCancellation()
                        guard let self, self.activity?.id == current.id,
                              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return }
                        self.saveAvatar(data, key: key)
                        var state = current.content.state
                        state.avatarRevision += 1
                        await current.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 0))
                    } catch { /* The initials remain usable without a network connection. */ }
                }
            }
        } catch {
            sharedDefaults?.removeObject(forKey: key)
            self.error = "暂时无法挂上灵动岛：" + error.localizedDescription
        }
    }

    func update(store: AppStore, rotateGreeting: Bool = false) {
        refresh()
        guard let current = activity,
              (current.attributes.backend ?? "vps") == store.activeBackend.rawValue else { return }
        var state = current.content.state
        state.name = store.agentDisplayName
        if rotateGreeting || state.greeting == nil {
            state.pokeStatus = nil
            state.greeting = ChatWelcomeLines.next(after: state.greeting ?? "")
            sharedDefaults?.set(state.greeting, forKey: "companionGreeting")
            if store.activeBackend == .vps { WatchSyncBridge.shared.publishGreeting(state.greeting ?? "") }
        }
        guard state != current.content.state else { return }
        Task { await current.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 0)) }
    }

    func refreshAppearance() {
        refresh()
        guard let current = activity else { return }
        var state = current.content.state
        state.avatarRevision += 1
        Task { await current.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 0)) }
    }

    func end() async {
        guard !working else { return }
        working = true
        defer { working = false }
        avatarTask?.cancel(); avatarTask = nil
        stateTask?.cancel(); stateTask = nil
        for current in Activity<VesperCompanionAttributes>.activities {
            await current.end(nil, dismissalPolicy: .immediate)
            sharedDefaults?.removeObject(forKey: current.attributes.avatarKey)
        }
        activity = nil; isActive = false; error = nil
    }

    private func saveAvatar(_ data: Data, key: String) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { _ in
            let scale = max(96 / image.size.width, 96 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (96 - size.width) / 2, y: (96 - size.height) / 2, width: size.width, height: size.height))
        }
        sharedDefaults?.set(thumbnail.pngData(), forKey: key)
    }
}
/// The intent runs in the app process without bringing its window forward.
@MainActor enum CompanionPokeDelivery {
    private static var inFlight = Set<String>()
    struct Target: Codable, Equatable { var conversationID: String; var model: String }
    static func targetURL(_ api: APIClient) -> URL? {
        ChatRecentCache.directory(api: api)?.appendingPathComponent("companion-target.json")
    }
    static func remember(api: APIClient, conversationID: String, model: String) {
        guard !conversationID.isEmpty, let file = targetURL(api),
              let data = try? JSONEncoder().encode(Target(conversationID: conversationID, model: model)) else { return }
        if (try? Data(contentsOf: file)) == data { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func target(_ api: APIClient) -> Target? {
        guard let file = targetURL(api), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Target.self, from: data)
    }
    static func send(avatarKey: String, workspace: ChatBackendWorkspace) async throws {
        guard let activity = Activity<VesperCompanionAttributes>.activities.first(where: {
            $0.attributes.avatarKey == avatarKey && ($0.activityState == .active || $0.activityState == .stale)
        }) else { throw ServiceError(message: "锁屏陪伴已结束，请在 Vesper 里重新开启。") }
        guard !inFlight.contains(avatarKey) else { return }
        inFlight.insert(avatarKey)
        defer { inFlight.remove(avatarKey) }
        func display(_ text: String) async {
            var state = activity.content.state; state.pokeStatus = text
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        do {
            guard let backend = VesperBackend(rawValue: activity.attributes.backend ?? "vps"), backend == .vps else {
                throw ServiceError(message: "后台敲一下暂仅支持 VPS 聊天。")
            }
            let runtime = workspace.runtime(backend), store = runtime.store
            let api = store.api
            guard !api.token.isEmpty else { throw ServiceError(message: "请先在 Vesper 中连接聊天。") }
            guard let destination = target(api), let file = targetURL(api) else {
                throw ServiceError(message: "先打开一次要敲的聊天，再回来敲一下。")
            }
            let key = "companionPoke." + file.deletingLastPathComponent().lastPathComponent + "." + destination.conversationID
            let defaults = UserDefaults.standard
            if Date().timeIntervalSince1970 - defaults.double(forKey: key + ".accepted") < 15 {
                await display("已敲一下"); return
            }
            // Keep the same request ID after a lost receipt, including process relaunch.
            let requestID = defaults.string(forKey: key) ?? UUID().uuidString.lowercased()
            defaults.set(requestID, forKey: key)
            let instructions = store.resolvedAgentInstructions(defaults.string(forKey: "nativeInstructions"))
                + ChatOrganization.instructions(api: api, conversation: destination.conversationID)
            let body: JSONValue = .object(["requestId": .string(requestID), "conversationId": .string(destination.conversationID),
                "instructions": .string(String(instructions.prefix(16000))), "name": .string(String(store.agentDisplayName.prefix(80))),
                "userName": .string(String(store.document("profile")["userName"].string.prefix(80))), "model": .string(destination.model),
                "originDevice": .string(ChatDeviceOrigin.current)])
            var request = URLRequest(url: try APIClient.validatedURL(api.historyURL, path: "/companion/poke"))
            request.httpMethod = "POST"; request.timeoutInterval = 12
            request.setValue("Bearer " + api.token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            await display("正在敲一下…")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                if status == 410 { defaults.removeObject(forKey: key); throw ServiceError(message: "这个聊天已删除，请打开另一个聊天。") }
                throw ServiceError(message: "未确认送达，点按可重试。")
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard value["ok"].bool, value["conversationId"].string == destination.conversationID,
                  !value["requestId"].string.isEmpty else { throw ServiceError(message: "未确认送达，点按可重试。") }
            defaults.removeObject(forKey: key)
            defaults.set(Date().timeIntervalSince1970, forKey: key + ".accepted")
            await display(value["status"].string == "failed" ? "已敲到，回复暂未完成" : "已敲一下")
        } catch {
            await display((error as? ServiceError)?.message ?? "未确认送达，点按可重试。")
            throw error
        }
    }
}
#endif
