import ActivityKit

struct VesperCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isVideo: Bool
    }

    var startedAt: Date
}
