import ActivityKit
import Foundation
import AppIntents

struct VesperCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isVideo: Bool
        var muted: Bool
        var speakerEnabled: Bool
    }

    var startedAt: Date
}

@MainActor enum VesperCallControlBridge {
    static var handle: ((String) throws -> Void)?
}

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
