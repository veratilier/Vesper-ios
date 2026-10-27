import ActivityKit
import Foundation
import AppIntents
import SwiftUI

#if !targetEnvironment(macCatalyst)
enum CompanionLeadingStyle: String, CaseIterable {
    case avatar, pixelSnake

    static let key = "companionLeadingStyle"
    static let appGroup = "group.com.vera.vesper.native"
    static var current: Self {
        let value = UserDefaults(suiteName: appGroup)?.string(forKey: key) ?? "pixelSnake"
        return Self(rawValue: value) ?? .pixelSnake
    }
}

/// Transparent pixel sprite shared by the app preview and the Live Activity.
struct CompanionPixelSnake: View {
    let size: CGFloat
    var pose = 0

    var body: some View {
        Image("CompanionPixelSnake")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: size, height: size)
        .offset(x: pose == 1 ? 1 : 0, y: pose == 1 ? -1 : 0)
        .scaleEffect(pose == 2 ? 1.04 : 1)
        .accessibilityLabel("像素小蛇")
    }
}
#endif

#if !targetEnvironment(macCatalyst)
struct VesperCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isVideo: Bool
        var muted: Bool
        var speakerEnabled: Bool
        var avatarRevision = 0
        var name: String? = nil
        var displayName: String { name?.isEmpty == false ? name! : "Rowan" }
    }

    var startedAt: Date
}

/// Kept only to decode and dismiss activities created by older installations.
struct VesperChatTaskAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var name: String
        var phase: String
    }
    var startedAt: Date
    var conversationID: String
    var backend: String
}

#endif

@MainActor enum VesperCallControlBridge {
    static var handle: ((String) throws -> Void)?
}

@MainActor enum VesperCompanionPokeBridge {
    static var handle: ((String) async throws -> Void)?
}

#if !targetEnvironment(macCatalyst)
struct VesperCallControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Control Vesper call"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Control") var control: String

    init() { control = "" }
    init(_ control: String) { self.control = control }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            guard let handle = VesperCallControlBridge.handle else {
                throw NSError(domain: "Vesper.Call", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The call is no longer active."])
            }
            try handle(control)
        }
        return .result()
    }
}

#endif

#if !targetEnvironment(macCatalyst)
/// Independent of voice calls: a user-started, local companionship session.
struct VesperCompanionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var avatarRevision = 0
        var name: String? = nil
        var greeting: String? = nil
        var pokeStatus: String? = nil
        var displayName: String { name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : "Rowan" }
    }
    var startedAt: Date
    var avatarKey: String
    var backend: String? = nil
}

struct PokeVesperCompanionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "敲一下"
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Companion") var avatarKey: String
    init() { avatarKey = "" }
    init(_ avatarKey: String) { self.avatarKey = avatarKey }
    @MainActor func perform() async throws -> some IntentResult {
        guard let handle = VesperCompanionPokeBridge.handle else {
            throw NSError(domain: "Vesper.Poke", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂时无法敲一下，请稍后重试。"])
        }
        try await handle(avatarKey)
        return .result()
    }
}

struct EndVesperCompanionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "收起陪伴灵动岛"
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult {
        for activity in Activity<VesperCompanionAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            UserDefaults(suiteName: "group.com.vera.vesper.native")?.removeObject(forKey: activity.attributes.avatarKey)
        }
        return .result()
    }
}

#endif
