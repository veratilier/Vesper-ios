import Foundation
import CryptoKit
import Combine

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
    var displayTitle: String { title.isEmpty ? "A letter from \(author)" : title }
    var isLocked: Bool { locked == true }
    var upcoming: Bool { unlockAt.flatMap(LetterDates.parse).map { $0 > Date() } ?? false }
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
    private var api: APIClient?
    private var generation = UUID()
    private var decoder = JSONDecoder()
    private var serverOffset: TimeInterval = 0
    func upcoming(_ letter: VesperLetter) -> Bool { letter.unlockAt.flatMap(LetterDates.parse).map { $0 > Date().addingTimeInterval(serverOffset) } ?? false }
    func configure(_ api: APIClient) {
        generation = UUID(); self.api = api; letters = []; cursor = ""; status = ""; loading = false; saving = false; serverOffset = 0
        draft = LetterDraftCache.load(api)
    }
    private func decode(_ value: JSONValue) throws -> VesperLetter { try decoder.decode(VesperLetter.self, from: JSONEncoder().encode(value)) }
    func saveDraft() {
        guard let api else { return }
        do { try LetterDraftCache.save(draft, api: api); status = "Draft saved" } catch { status = error.localizedDescription }
    }
    func load(reset: Bool = true) async {
        guard let api, !loading else { return }
        let request = generation; loading = true
        defer { if generation == request { loading = false } }
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "limit", value: "50")]
            if !reset && !cursor.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: cursor)) }
            let result = try await api.request("/api/letters?" + (query.percentEncodedQuery ?? ""))
            guard request == generation else { return }
            if let server = LetterDates.parse(result["serverTime"].string) { serverOffset = server.timeIntervalSinceNow }
            let incoming = try result["letters"].array.map(decode)
            var seen = Set<String>(); letters = ((reset ? [] : letters) + incoming).filter { seen.insert($0.id).inserted }
            cursor = result["before"].string; status = ""
        } catch { if generation == request { status = error.localizedDescription } }
    }
    private func replace(_ letter: VesperLetter) {
        if let i = letters.firstIndex(where: { $0.id == letter.id }) { letters[i] = letter } else { letters.insert(letter, at: 0) }
    }
    func open(_ letter: VesperLetter) async -> VesperLetter? {
        guard let api, !saving else { return nil }
        let request = generation; saving = true; defer { if request == generation { saving = false } }
        do {
            let result = try await api.request("/api/letters", method: "PATCH", body: .object(["id": .string(letter.id), "action": .string("read")]))
            guard request == generation else { return nil }
            let opened = try decode(result["letter"])
            guard !opened.isLocked, opened.text != nil else { throw ServiceError(message: "This letter is still sealed.") }
            replace(opened); status = ""; return opened
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
