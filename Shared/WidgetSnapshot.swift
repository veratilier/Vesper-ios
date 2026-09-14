import Foundation

struct WidgetSnapshot: Codable {
    static let group = "group.com.vera.vesper.native"
    let updatedAt: Date
    let text: String
    let values: [String: Double]
    static func read(_ key: String) -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.group)?.set(data, forKey: key)
    }
}
