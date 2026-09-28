import ActivityKit
import Foundation

@MainActor final class CallLiveActivity {
    static let shared = CallLiveActivity()
    private var activity: Activity<VesperCallAttributes>?

    func start(at date: Date, isVideo: Bool, avatar: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
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
                content: ActivityContent(state: .init(isVideo: isVideo), staleDate: nil),
                pushType: nil
            )
        } catch {
            // The in-app call remains usable if Live Activities are disabled.
            activity = nil
            UserDefaults(suiteName: "group.com.vera.vesper.native")?.removeObject(forKey: "activeCallAvatar")
        }
    }

    func update(isVideo: Bool) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: .init(isVideo: isVideo), staleDate: nil)) }
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
