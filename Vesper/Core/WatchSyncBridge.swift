#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import WatchConnectivity

/// Supplies the watch with the latest VPS credentials and room identity.
/// The watch keeps its own HTTPS connection once provisioned.
final class WatchSyncBridge: NSObject, WCSessionDelegate {
    static let shared = WatchSyncBridge()
    private let session = WCSession.default
    private var pending: [String: Any] = [:]
    private var avatarTask: Task<Void, Never>?
    private var cachedAvatarSource = ""
    private var cachedAvatarData: Data?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    @MainActor func publish(store: AppStore) {
        let token = store.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let profile = store.document("profile")
        let sharedDefaults = UserDefaults(suiteName: "group.com.vera.vesper.native")
        var greeting = sharedDefaults?.string(forKey: "companionGreeting") ?? ""
        if greeting.isEmpty {
            greeting = ChatWelcomeLines.next(after: "")
            sharedDefaults?.set(greeting, forKey: "companionGreeting")
        }
        pending = [
            "token": token,
            "historyURL": store.historyURL,
            "agentName": String(store.agentDisplayName.prefix(80)),
            "userName": String((profile["userName"].string.isEmpty ? "Vera" : profile["userName"].string).prefix(80)),
            "conversationId": profile["mainConversationId"].string,
            "instructions": String(store.resolvedAgentInstructions(profile["agentInstructions"].string).prefix(16_000)),
            "greeting": greeting,
            "updatedAt": Date().timeIntervalSince1970
        ]
        pending.merge(appearanceSettings(), uniquingKeysWith: { _, latest in latest })
        let avatarSource = profile["agentAvatar"].string
        // The source may be a full-size data URI. Only send a presence flag
        // and the small rendered thumbnail over WatchConnectivity.
        pending["avatarAvailable"] = !avatarSource.isEmpty
        let avatarIdentity = store.baseURL + "\n" + avatarSource
        if avatarIdentity == cachedAvatarSource, let cachedAvatarData {
            pending["avatarData"] = cachedAvatarData
        } else {
            avatarTask?.cancel()
            cachedAvatarSource = avatarIdentity
            cachedAvatarData = nil
            if !avatarSource.isEmpty {
                let request = ChatAvatarSource(source: avatarSource, baseURL: store.baseURL)
                avatarTask = Task { @MainActor in
                    guard let image = await ChatAvatarImageCache.shared.image(for: request),
                          !Task.isCancelled, cachedAvatarSource == avatarIdentity else { return }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 72), format: format).image { _ in
                        let scale = max(72 / image.size.width, 72 / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        image.draw(in: CGRect(x: (72 - size.width) / 2, y: (72 - size.height) / 2,
                                              width: size.width, height: size.height))
                    }
                    guard let data = thumbnail.jpegData(compressionQuality: 0.72) else { return }
                    cachedAvatarData = data
                    pending["avatarData"] = data
                    publishPending()
                }
            }
        }
        publishPending()
    }

    @MainActor func publishAppearance() {
        guard !pending.isEmpty else { return }
        pending.merge(appearanceSettings(), uniquingKeysWith: { _, latest in latest })
        publishPending()
    }

    private func appearanceSettings() -> [String: Any] {
        let defaults = UserDefaults.standard
        return [
            "glassStyle": defaults.string(forKey: "glassStyle") ?? "liquid",
            "glassFrost": defaults.double(forKey: "glassFrost") > 0,
            "glassTransparency": min(1, max(0, defaults.double(forKey: "glassTransparency"))),
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled
        ]
    }

    @MainActor func publishGreeting(_ greeting: String) {
        guard !greeting.isEmpty, !pending.isEmpty else { return }
        pending["greeting"] = greeting
        publishPending()
    }

    @MainActor private func publishPending() {
        UserDefaults.standard.set([
            "activation": session.activationState.rawValue,
            "paired": session.isPaired,
            "watchInstalled": session.isWatchAppInstalled,
            "reachable": session.isReachable,
            "name": pending["agentName"] as? String ?? "",
            "avatarBytes": (pending["avatarData"] as? Data)?.count ?? 0,
            "time": Date().timeIntervalSince1970
        ], forKey: "watchSyncStatus")
        guard session.activationState == .activated,
              session.isPaired, !pending.isEmpty else { return }
        do {
            try session.updateApplicationContext(pending)
            // Application context can wait until watchOS schedules delivery.
            // Also update an open watch app immediately.
            if session.isReachable {
                session.sendMessage(pending, replyHandler: nil, errorHandler: { error in
                    NSLog("Vesper watch live profile sync deferred: %@", error.localizedDescription)
                })
            }
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "watchSyncError")
            NSLog("Vesper watch profile sync failed: %@", error.localizedDescription)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.publishPending() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.publishPending() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.publishPending() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "profile" else { replyHandler([:]); return }
        DispatchQueue.main.async { replyHandler(self.pending) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
