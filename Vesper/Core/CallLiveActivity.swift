#if targetEnvironment(macCatalyst)
import Foundation
// macOS shows the in-app call; Live Activities belong to the iPhone target.
@MainActor final class CallLiveActivity {
    static let shared = CallLiveActivity()
    func start(at date: Date, isVideo: Bool, avatar: String) {}
    func update(isVideo: Bool) {}
    func updateControls(muted: Bool, speakerEnabled: Bool) {}
    func end() {}
    func endStale() async {}
}
#else
import ActivityKit
import Foundation

@MainActor final class CallLiveActivity {
    static let shared = CallLiveActivity()
    private var activity: Activity<VesperCallAttributes>?
    private var isVideo = false
    private var muted = false
    private var speakerEnabled = false

    func start(at date: Date, isVideo: Bool, avatar: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.isVideo = isVideo
        muted = InAppCalls.shared.muted
        speakerEnabled = InAppCalls.shared.speakerEnabled
        if avatar.hasPrefix("data:image/"), let comma = avatar.firstIndex(of: ","),
           let data = Data(base64Encoded: String(avatar[avatar.index(after: comma)...])) {
            UserDefaults(suiteName: "group.com.vera.vesper.native")?.set(data, forKey: "activeCallAvatar")
        } else {
            UserDefaults(suiteName: "group.com.vera.vesper.native")?.removeObject(forKey: "activeCallAvatar")
        }
        // A previous process may have left a stale island behind after a crash.
        let stale = Activity<VesperCallAttributes>.activities
        Task { for item in stale { await item.end(nil, dismissalPolicy: .immediate) } }
        do {
            activity = try Activity.request(
                attributes: VesperCallAttributes(startedAt: date),
                content: ActivityContent(state: .init(isVideo: isVideo, muted: muted,
                                                     speakerEnabled: speakerEnabled), staleDate: nil),
                pushType: nil
            )
        } catch {
            // The in-app call remains usable if Live Activities are disabled.
            activity = nil
            UserDefaults(suiteName: "group.com.vera.vesper.native")?.removeObject(forKey: "activeCallAvatar")
        }
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
                                                      speakerEnabled: speakerEnabled)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        let current = activity
        activity = nil
        UserDefaults(suiteName: "group.com.vera.vesper.native")?.removeObject(forKey: "activeCallAvatar")
        if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
    }

    func endStale() async {
        guard activity == nil else { return }
        UserDefaults(suiteName: "group.com.vera.vesper.native")?.removeObject(forKey: "activeCallAvatar")
        let stale = Activity<VesperCallAttributes>.activities
        for item in stale {
            guard item.id != activity?.id else { continue }
            await item.end(nil, dismissalPolicy: .immediate)
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
        let current = Activity<VesperCompanionAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
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

    func start(avatar: String, baseURL: String) {
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
                attributes: VesperCompanionAttributes(startedAt: .now, avatarKey: key),
                content: ActivityContent(state: .init(), staleDate: nil, relevanceScore: 0),
                pushType: nil)
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
                        await current.update(ActivityContent(state: .init(avatarRevision: 1), staleDate: nil, relevanceScore: 0))
                    } catch { /* The initials remain usable without a network connection. */ }
                }
            }
        } catch {
            sharedDefaults?.removeObject(forKey: key)
            self.error = "暂时无法挂上灵动岛：" + error.localizedDescription
        }
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
#endif
