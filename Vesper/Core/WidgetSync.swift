import WidgetKit
import Foundation

@MainActor enum WidgetSync {
    static func desire(_ data: JSONValue) {
        var values: [String: Double] = [:]
        for (key, _) in DesireEmotion.fields {
            if case .number(let value) = data["values"][key] { values[key] = value }
        }
        WidgetSnapshot(updatedAt: AlbumPresentation.date(data["updatedAt"].string) ?? Date(), text: data["reason"].string.isEmpty ? "等待情绪评估" : data["reason"].string, values: values).save("desire")
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperDesireWidget")
    }
    static func usage(_ remaining: Int?) {
        guard let remaining else { return }
        WidgetSnapshot(updatedAt: Date(), text: "Weekly usage", values: ["remaining": Double(remaining)]).save("usage")
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperUsageWidget")
    }
    static func clear() {
        for key in ["desire", "usage", "notes"] { UserDefaults(suiteName: WidgetSnapshot.group)?.removeObject(forKey: key) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
