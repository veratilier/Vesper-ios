import Foundation

/// Only the watch app and its WidgetKit extension can read this container.
enum WatchWidgetSettings {
    static let suiteName = "group.com.vera.vesper.watch"

    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func update(token: String, historyURL: String, conversationID: String,
                       agentName: String, userName: String, instructions: String,
                       greeting: String, avatarData: Data?) {
        guard let defaults else { return }
        defaults.set(token, forKey: "token")
        defaults.set(historyURL, forKey: "historyURL")
        defaults.set(conversationID, forKey: "conversationId")
        defaults.set(agentName, forKey: "agentName")
        defaults.set(userName, forKey: "userName")
        defaults.set(instructions, forKey: "instructions")
        defaults.set(greeting, forKey: "greeting")
        if let avatarData {
            defaults.set(avatarData, forKey: "avatarData")
        } else {
            defaults.removeObject(forKey: "avatarData")
        }
    }

    static var agentName: String {
        let value = defaults?.string(forKey: "agentName") ?? ""
        return value.isEmpty ? "Vesper" : value
    }

    static var greeting: String {
        let value = defaults?.string(forKey: "greeting") ?? ""
        return value.isEmpty ? "Come as you are." : value
    }

    static var avatarData: Data? { defaults?.data(forKey: "avatarData") }

    static var canPoke: Bool {
        guard let defaults else { return false }
        return !(defaults.string(forKey: "token") ?? "").isEmpty &&
            !(defaults.string(forKey: "conversationId") ?? "").isEmpty
    }

    static func poke() async throws {
        guard let defaults,
              let token = defaults.string(forKey: "token"), !token.isEmpty,
              let room = defaults.string(forKey: "conversationId"), !room.isEmpty,
              let baseString = defaults.string(forKey: "historyURL"),
              let base = URL(string: baseString + (baseString.hasSuffix("/") ? "" : "/")),
              base.scheme == "https",
              let url = URL(string: "companion/poke", relativeTo: base)?.absoluteURL else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "requestId": UUID().uuidString,
            "conversationId": room,
            "origin": "watch",
            "originDevice": "Apple Watch",
            "name": defaults.string(forKey: "agentName") ?? "Vesper",
            "userName": defaults.string(forKey: "userName") ?? "Vera",
            "instructions": defaults.string(forKey: "instructions") ?? ""
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
