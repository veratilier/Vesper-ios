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

/// Decorative greetings shared by Chat, the companion Live Activity and the Home Screen card.
enum ChatWelcomeLines {
    static let all = [
        "A place for today, too.", "Come as you are.", "A little room for us.",
        "There’s room for your whole day.", "Hello again, lovely you.",
        "Leave a little of today here.", "One thought, or a thousand.",
        "A quiet place to begin.", "We can take our time.",
        "For all the little things.", "A little closer, a little softer.",
        "No perfect words needed.", "Something to tell, something to keep.",
        "The day can wait a moment.", "Let’s make a little space.", "Here, with you."
    ]

    static func next(after previous: String) -> String {
        all.filter { $0 != previous }.randomElement() ?? all[0]
    }
}

/// Local-only Home Screen state. A tap changes the pose and greeting; WidgetKit
/// also requests a fresh line periodically when the system permits a refresh.
struct CompanionCardSnapshot: Codable {
    static let key = "companionCard.v1"
    static let refreshInterval: TimeInterval = 2 * 60 * 60
    var greeting: String
    var pose: Int
    var updatedAt: Date

    static func current(at now: Date = .now) -> Self {
        let saved = read()
        guard let saved, now.timeIntervalSince(saved.updatedAt) < refreshInterval else {
            return advance(at: now)
        }
        return saved
    }

    @discardableResult static func advance(at now: Date = .now) -> Self {
        let previous = read()
        let value = Self(greeting: ChatWelcomeLines.next(after: previous?.greeting ?? ""),
                         pose: ((previous?.pose ?? -1) + 1) % 3, updatedAt: now)
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults(suiteName: WidgetSnapshot.group)?.set(data, forKey: key)
        }
        return value
    }

    private static func read() -> Self? {
        guard let data = UserDefaults(suiteName: WidgetSnapshot.group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Device-local JPEG previews for configurable Home Screen picture widgets.
/// Photos are never added to Vesper's synced documents or chat history.
struct WidgetPictureItem: Codable, Identifiable, Equatable {
    let id: String
    var name: String
}

enum WidgetPictureStore {
    private static let indexName = "home-pictures-v2.json"
    private static let legacyName = "home-picture-v1.jpg"

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.group)
    }

    private static func imageURL(for id: String) -> URL? {
        directory?.appendingPathComponent("home-picture-\(id).jpg")
    }

    static func items() -> [WidgetPictureItem] {
        guard let url = directory?.appendingPathComponent(indexName),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([WidgetPictureItem].self, from: data) else { return [] }
        return items
    }

    static func image(for id: String) -> Data? {
        guard let url = imageURL(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func saveIndex(_ items: [WidgetPictureItem]) throws {
        guard let url = directory?.appendingPathComponent(indexName) else {
            throw NSError(domain: "Vesper.WidgetPicture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The widget's shared storage is unavailable."])
        }
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
    }

    @discardableResult static func add(_ jpeg: Data) throws -> WidgetPictureItem {
        let existing = items()
        let id = UUID().uuidString
        let used = Set(existing.map(\.name))
        var number = 1
        while used.contains("Photo \(number)") { number += 1 }
        let item = WidgetPictureItem(id: id, name: "Photo \(number)")
        guard let url = imageURL(for: id) else {
            throw NSError(domain: "Vesper.WidgetPicture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The widget's shared storage is unavailable."])
        }
        try jpeg.write(to: url, options: .atomic)
        do { try saveIndex(existing + [item]) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return item
    }

    static func rename(_ id: String, to name: String) throws {
        var current = items()
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].name = name
        try saveIndex(current)
    }

    static func remove(_ id: String) throws {
        let current = items()
        guard current.contains(where: { $0.id == id }) else { return }
        try saveIndex(current.filter { $0.id != id })
        if let url = imageURL(for: id) { try? FileManager.default.removeItem(at: url) }
    }

    /// Keep the picture selected in the brief single-photo implementation.
    static func migrateLegacyPicture() throws {
        guard let legacyURL = directory?.appendingPathComponent(legacyName),
              let data = try? Data(contentsOf: legacyURL) else { return }
        _ = try add(data)
        try? FileManager.default.removeItem(at: legacyURL)
    }
}

/// Small, device-local preview shared with the Lock Screen widgets.
struct LockWidgetSnapshot: Codable {
    static let key = "lockWidgets.v1"
    var name = "Ash"
    var avatarSource = ""
    var avatarData: Data?
    var message = ""
    var messageDate: Date?
    var song = ""
    var artist = ""
    var isPlaying = false

    static func read() -> Self {
        guard let data = UserDefaults(suiteName: WidgetSnapshot.group)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: WidgetSnapshot.group)?.set(data, forKey: Self.key)
    }
}
