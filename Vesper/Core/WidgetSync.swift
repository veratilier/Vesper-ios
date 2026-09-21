import WidgetKit
import Foundation

@MainActor enum WidgetSync {
    static func notes(_ notes: JSONValue) {
        let text = notes.array.first?["text"].string ?? "No notes yet."
        WidgetSnapshot(updatedAt: Date(), text: String(text.prefix(1000)), values: [:]).save("notes")
        WidgetCenter.shared.reloadTimelines(ofKind: "VesperNotesWidget")
    }
    static func desire(_ data: JSONValue) {
        var values: [String: Double] = [:]
        for key in ["longing", "tenderness", "playfulness", "intensity", "attachment", "possessiveness"] {
            if case .number(let value) = data[key] { values[key] = value }
        }
        guard !values.isEmpty else { return }
        WidgetSnapshot(updatedAt: Date(), text: "此刻的潮汐", values: values).save("desire")
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
