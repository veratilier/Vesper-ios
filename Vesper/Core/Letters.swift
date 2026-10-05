import Foundation
import CryptoKit
import Combine
import UserNotifications

struct LetterMark: Codable, Equatable {
    var read: Bool
    var kept: Bool
    var readAt: String?
}
struct VesperLetter: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var text: String?
    var author: String
    var recipient: String?
    var createdAt: String
    var unlockAt: String?
    var replyTo: String?
    var locked: Bool?
    var read: Bool?
    var kept: Bool?
    var marks: [String: LetterMark]?
    var displayTitle: String { title.isEmpty ? "A letter from \(author)" : title }
    var isLocked: Bool { locked == true }
    var upcoming: Bool { unlockAt.flatMap(LetterDates.parse).map { $0 > Date() } ?? false }
    var readerName: String { recipient ?? (author == "Vera" ? "Rowan" : "Vera") }
    var readerRead: Bool? { readerName == "Rowan" ? marks?["Rowan"]?.read : marks?["Vera"]?.read ?? read ?? false }
    var readLabel: String {
        let name = readerName == "Vera" ? "你" : readerName + " "
        guard let readerRead else { return name + "暂无回执" }
        return name + (readerRead ? "已读" : "未读")
    }
    var keepers: [String] { ["Vera", "Rowan"].filter { marks?[$0]?.kept == true || ($0 == "Vera" && kept == true) } }
    var keepLabels: [String] { keepers.map { ($0 == "Vera" ? "你" : $0 + " ") + "已收藏" } }
    var isKept: Bool { !keepers.isEmpty }
    func matchesFilter(_ filter: String) -> Bool { filter == "All" || (filter == "Unread" ? readerRead == false : isKept) }
}
enum LetterDates {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func display(_ string: String) -> String { parse(string)?.formatted(date: .abbreviated, time: .shortened) ?? string }
}
struct LetterDraft: Codable, Equatable {
    var id = UUID().uuidString
    var title = ""
    var text = ""
    var scheduled = false
    var unlockAt = Date().addingTimeInterval(86400)
    var replyTo: String?
    var deliveryAttempted = false
    var payload: JSONValue {
        var result: [String: JSONValue] = ["id": .string(id), "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))]
        if scheduled { result["unlockAt"] = .string(ISO8601DateFormatter().string(from: unlockAt)) }
        if let replyTo { result["replyTo"] = .string(replyTo) }
        return .object(result)
    }
}
enum LetterDraftCache {
    private static func file(_ api: APIClient) -> URL? {
        guard !api.token.isEmpty, let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let scope = SHA256.hash(data: Data((api.baseURL + "\n" + api.token).utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("letter-draft-\(scope).json")
    }
    static func load(_ api: APIClient) -> LetterDraft {
        guard let url = file(api), let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(LetterDraft.self, from: data) else { return LetterDraft() }
        return draft
    }
    static func save(_ draft: LetterDraft, api: APIClient) throws {
        guard let url = file(api) else { throw ServiceError(message: "Connect this device before saving a draft.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
@MainActor final class LettersStore: ObservableObject {
    @Published var letters: [VesperLetter] = []
    @Published var draft = LetterDraft()
    @Published var status = ""
    @Published var loading = false
    @Published var saving = false
    @Published var cursor = ""
    var configured: Bool { api != nil }
    private var api: APIClient?
    private var generation = UUID()
    private var revision = 0
    private var decoder = JSONDecoder()
    private var serverOffset: TimeInterval = 0
    func upcoming(_ letter: VesperLetter) -> Bool { letter.unlockAt.flatMap(LetterDates.parse).map { $0 > Date().addingTimeInterval(serverOffset) } ?? false }
    func configure(_ api: APIClient) {
        generation = UUID(); revision = 0; self.api = api; letters = []; cursor = ""; status = ""; loading = false; saving = false; serverOffset = 0
        draft = LetterDraftCache.load(api)
    }
    private func decode(_ value: JSONValue) throws -> VesperLetter { try decoder.decode(VesperLetter.self, from: JSONEncoder().encode(value)) }
    func saveDraft(showStatus: Bool = true) {
        guard let api else { return }
        do { try LetterDraftCache.save(draft, api: api); if showStatus { status = "Draft saved" } } catch { status = error.localizedDescription }
    }
    func load(reset: Bool = true) async {
        guard let api, !loading else { return }
        let request = generation, version = revision; loading = true
        defer { if generation == request { loading = false } }
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "limit", value: "50")]
            if !reset && !cursor.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: cursor)) }
            let result = try await api.request("/api/letters?" + (query.percentEncodedQuery ?? ""))
            guard request == generation, version == revision else { return }
            if let server = LetterDates.parse(result["serverTime"].string) { serverOffset = server.timeIntervalSinceNow }
            let incoming = try result["letters"].array.map(decode)
            var seen = Set<String>(); letters = ((reset ? [] : letters) + incoming).filter { seen.insert($0.id).inserted }
            cursor = result["before"].string; status = ""
        } catch { if generation == request { status = error.localizedDescription } }
    }
    private func replace(_ letter: VesperLetter) {
        revision += 1
        if let i = letters.firstIndex(where: { $0.id == letter.id }) { letters[i] = letter } else { letters.insert(letter, at: 0) }
    }
    func open(id: String) async -> VesperLetter? {
        guard let api else { return nil }
        let request = generation
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "id", value: id)]
            let result = try await api.request("/api/letters?" + (query.percentEncodedQuery ?? ""))
            guard request == generation else { return nil }
            return await open(try decode(result["letter"]))
        } catch { if request == generation { status = error.localizedDescription }; return nil }
    }
    func open(_ letter: VesperLetter) async -> VesperLetter? {
        guard let api, !saving else { return nil }
        let request = generation; saving = true; defer { if request == generation { saving = false } }
        do {
            let result = try await api.request("/api/letters", method: "PATCH", body: .object(["id": .string(letter.id), "action": .string("read")]))
            guard request == generation else { return nil }
            let opened = try decode(result["letter"])
            guard !opened.isLocked, opened.text != nil else { throw ServiceError(message: "This letter is still sealed.") }
            replace(opened); LetterInbox.shared.markRead(opened.id); status = ""; return opened
        } catch { if request == generation { status = error.localizedDescription }; return nil }
    }
    func keep(_ letter: VesperLetter) async -> VesperLetter? {
        guard let api, !saving else { return nil }
        let request = generation; saving = true; defer { if request == generation { saving = false } }
        do {
            let result = try await api.request("/api/letters", method: "PATCH", body: .object(["id": .string(letter.id), "action": .string("keep"), "kept": .bool(letter.kept != true)]))
            guard request == generation else { return nil }
            let updated = try decode(result["letter"]); replace(updated); status = ""; return updated
        } catch { if request == generation { status = error.localizedDescription }; return nil }
    }
    func reply(to letter: VesperLetter) -> Bool {
        guard draft.text.isEmpty, !draft.deliveryAttempted else { status = "Finish your existing draft before starting a reply."; return false }
        draft = LetterDraft(); draft.title = "Re: " + letter.displayTitle; draft.replyTo = letter.id; saveDraft(); return true
    }
    func post() async -> VesperLetter? {
        guard let api, !saving else { return nil }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.text.utf16.count <= 12000, draft.title.utf16.count <= 120 else { status = "Write a letter under 12,000 characters and a title under 120 characters."; return nil }
        guard !draft.scheduled || draft.unlockAt.timeIntervalSince1970.isFinite && draft.unlockAt.timeIntervalSinceNow <= 10 * 366 * 86400 else { status = "Choose an opening date within ten years."; return nil }
        let request = generation; saving = true; defer { if request == generation { saving = false } }
        do {
            // Persist the immutable retry payload before delivery. An uncertain
            // network response cannot create another letter or allow edits.
            draft.deliveryAttempted = true; try LetterDraftCache.save(draft, api: api)
            let result = try await api.request("/api/letters", method: "POST", body: draft.payload)
            guard request == generation else { return nil }
            let sent = try decode(result["letter"])
            guard sent.id == draft.id else { throw ServiceError(message: "Letter delivery was not confirmed.") }
            replace(sent); draft = LetterDraft()
            do { try LetterDraftCache.save(draft, api: api); status = "" }
            catch { status = "Sent. Could not clear the saved draft: " + error.localizedDescription }
            return sent
        } catch { if request == generation { status = error.localizedDescription }; return nil }
    }
}


@MainActor final class LetterNotificationRoute: ObservableObject {
    static let shared = LetterNotificationRoute()
    @Published var letterID: String?
}
struct LetterReminderCover: Decodable {
    let id: String
    let title: String
    let author: String
    let unlockAt: String
    let due: Bool
}
struct LetterReminderFeed: Decodable {
    let inbox: [LetterInboxCover]
    let reminders: [LetterReminderCover]
    let serverTime: String
}
struct LetterInboxCover: Decodable, Equatable {
    let id: String
    let unlockAt: String?
}
@MainActor final class LetterInbox: ObservableObject {
    static let shared = LetterInbox()
    @Published private(set) var hasUpdates = false
    @Published private(set) var covers: [LetterInboxCover] = []
    private let preferences: UserDefaults
    private var account = "", seen = Set<String>(), serverOffset: TimeInterval = 0
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    func update(_ covers: [LetterInboxCover], scope: String, serverTime: Date) {
        if account != scope {
            account = scope; seen = Set(preferences.stringArray(forKey: "vesperLetterSeen-" + scope) ?? [])
        }
        self.covers = covers; serverOffset = serverTime.timeIntervalSinceNow; tick()
    }
    func tick(now: Date = .now) {
        let time = now.addingTimeInterval(serverOffset)
        let value = covers.contains { !seen.contains($0.id) || ($0.unlockAt.flatMap(LetterDates.parse).map { $0 <= time } ?? true) }
        if value != hasUpdates { hasUpdates = value }
    }
    func markArrivalSeen(_ ids: [String]) {
        guard !account.isEmpty else { return }
        seen.formUnion(ids); preferences.set(Array(seen), forKey: "vesperLetterSeen-" + account); tick()
    }
    func markRead(_ id: String) { covers.removeAll { $0.id == id }; tick() }
    func clear() { covers = []; account = ""; seen = []; hasUpdates = false }
}
@MainActor enum LetterNotifications {
    private static var syncing = false
    private static var currentAccount = ""
    static func scope(_ api: APIClient) -> String {
        SHA256.hash(data: Data((api.baseURL + "\n" + api.token).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func request(_ cover: LetterReminderCover, scope: String, serverTime: Date) -> UNNotificationRequest? {
        guard let opening = LetterDates.parse(cover.unlockAt) else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "可以拆信了"
        content.body = cover.author + " 给你的「" + (cover.title.isEmpty ? "一封信" : cover.title) + "」现在可以打开了。"
        content.sound = .default
        content.userInfo = ["letterId":cover.id,"letterScope":scope]
        // Use the server's remaining interval, including seconds, instead of
        // trusting a possibly skewed phone clock or rounding to the minute.
        let delay = max(1, opening.timeIntervalSince(serverTime))
        return UNNotificationRequest(identifier: "letter-" + scope + "-" + cover.id, content: content,
                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
    }
    static func sync(_ api: APIClient) async {
        let account = scope(api); currentAccount = account
        guard !syncing else { return }; syncing = true; defer { syncing = false }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled, currentAccount == account else { return }
        let old = pending.filter { $0.identifier.hasPrefix("letter-") && !$0.identifier.hasPrefix("letter-" + account + "-") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard !api.token.isEmpty else { LetterInbox.shared.clear(); return }
        do {
            let value = try await api.request("/api/letters/reminders")
            guard !Task.isCancelled, currentAccount == account else { return }
            let feed = try JSONDecoder().decode(LetterReminderFeed.self, from: JSONEncoder().encode(value))
            guard let server = LetterDates.parse(feed.serverTime) else { return }
            LetterInbox.shared.update(feed.inbox, scope: account, serverTime: server)
            let allowed = Set(feed.reminders.map { "letter-" + account + "-" + $0.id })
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                $0.identifier.hasPrefix("letter-" + account + "-") && !allowed.contains($0.identifier)
            }.map(\.identifier))
            guard !feed.reminders.isEmpty else { return }
            var authorization = await center.notificationSettings().authorizationStatus
            if authorization == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                authorization = await center.notificationSettings().authorizationStatus
            }
            guard [.authorized, .provisional, .ephemeral].contains(authorization) else { return }
            let key = "vesperLetterNotifications-" + account
            var known = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            // Keep other date reminders; iOS has a finite pending request budget.
            let available = max(0, 60 - pending.filter { !$0.identifier.hasPrefix("letter-") }.count)
            let existing = Set(pending.map(\.identifier))
            var occupied = 0
            for cover in feed.reminders {
                let id = "letter-" + account + "-" + cover.id
                if existing.contains(id) { occupied += 1; continue }
                if known.contains(id) && cover.due { continue } // Already fired: never alert twice.
                guard occupied < available, let request = request(cover, scope: account, serverTime: server) else { continue }
                guard !Task.isCancelled, currentAccount == account else { return }
                try await center.add(request); occupied += 1; known.insert(id)
                UserDefaults.standard.set(Array(known), forKey: key)
            }
        } catch { /* Retry on the next refresh; letter access remains available. */ }
    }
}
