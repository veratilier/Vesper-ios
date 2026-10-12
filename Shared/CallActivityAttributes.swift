import ActivityKit
import Foundation
import AppIntents

#if !targetEnvironment(macCatalyst)
struct VesperCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isVideo: Bool
        var muted: Bool
        var speakerEnabled: Bool
    }

    var startedAt: Date
}

#endif

@MainActor enum VesperCallControlBridge {
    static var handle: ((String) throws -> Void)?
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
    }
    var startedAt: Date
    var avatarKey: String
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
