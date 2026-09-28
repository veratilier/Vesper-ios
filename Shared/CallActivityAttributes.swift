import ActivityKit
import Foundation

struct VesperCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isVideo: Bool
    }

    var startedAt: Date
}
