import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [JSONValue] = []
    @State private var evidence: [JSONValue] = []
    @State private var section = "Timeline"
    @State private var filter = "Recent"
    @State private var query = ""
    @State private var status = ""
    @State private var adding = false
    @State private var text = ""
    @State private var tags = ""
    @State private var busy = false
    private var visible: [JSONValue] {
        let selected = items.filter { item in
            switch filter {
            case "Current": return item["type"].string == "core" && item["reviewStatus"].string == "approved" && item["demotedAt"] == .null
            case "Corrected": return item["correctedAt"] != .null
            default: return true
            }
        }
        return selected.sorted { filter == "Recalled" ? $0["surfaceCount"].number > $1["surfaceCount"].number : $0["updatedAt"].string > $1["updatedAt"].string }
    }
    var body: some View {
        Page(title: "Memory", subtitle: "What we remember, and where it began.") {
            Picker("Memory view", selection: $section) {
                ForEach(["Timeline", "Relations", "Vault"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                TextField("Search memories", text: $query).submitLabel(.search).onSubmit { Task { await load() } }
                Button { Task { await load() } } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search memories")
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add memory")
            }.padding(14).background(.regularMaterial, in: Capsule())
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(VesperTheme.muted) }
            if section == "Timeline" {
                Picker("Sort and filter", selection: $filter) { ForEach(["Recent", "Current", "Corrected", "Recalled"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                ForEach(visible) { memory in
                    NavigationLink { MemoryDetailView(memory: memory) } label: { MemoryCard(memory: memory) }.buttonStyle(.plain)
                }
            } else if section == "Relations" {
                MemoryRelations(items: items)
            } else {
                Text("Original sources").font(.headline)
                if evidence.isEmpty { EmptyCard(title: "No original sources yet", message: "Older memories may not have a saved source. New saved messages retain their original text and attachment references here.") }
                ForEach(evidence) { source in
                    NavigationLink { EvidenceView(evidence: source) } label: {
                        GlassCard { VStack(alignment: .leading, spacing: 8) {
                            Text(source["content"].string.isEmpty ? "Attachment" : source["content"].string).lineLimit(3)
                            Text(source["createdAt"].string).font(.caption).foregroundStyle(VesperTheme.muted)
                        } }
                    }.buttonStyle(.plain)
                }
            }
        }.task { await load() }.refreshable { await load() }
        .sheet(isPresented: $adding) {
            EditorSheet(title: "New core memory", busy: busy, save: { Task { await save() } }) {
                FormField(label: "Memory", text: $text, multiline: true)
                FormField(label: "People, topics or places (comma separated)", text: $tags)
            }
        }
    }
    private func load() async {
        do {
            var params = URLComponents(); params.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "includeDemoted", value: "1"), URLQueryItem(name: "includeCandidates", value: "1")]
            let response = try await store.api.request("/api/memory?" + (params.percentEncodedQuery ?? "")); items = response["memories"].array
            status = items.isEmpty ? "No memories found." : ""
            do { let vault = try await store.api.request("/api/memory?view=vault"); evidence = vault["evidence"].array }
            catch { status = "Memories loaded. Original sources are unavailable: " + error.localizedDescription }
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { status = "Add a little more detail."; return }
        busy = true; defer { busy = false }
        do {
            _ = try await store.api.request("/api/memory", method: "POST", body: .object(["action": .string("create_core"), "body": .string(text), "tags": .string(tags)]))
            text = ""; tags = ""; adding = false; await load()
        } catch { store.error = error.localizedDescription }
    }
}
struct MemoryCard: View {
    let memory: JSONValue
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(memory["type"].string.replacingOccurrences(of: "_", with: " ")).font(.caption); Spacer(); if memory["pinned"].bool { Image(systemName: "pin.fill") } }
                Text(memory["body"].string).font(.body).lineLimit(6)
                Text(memory["demotedAt"] != .null ? "Historical · no longer active" : memory["reviewStatus"].string == "candidate" ? "Awaiting confirmation" : "Confirmed").font(.caption).foregroundStyle(VesperTheme.muted)
                Text(ChatPresentation.time(memory["updatedAt"].string)).font(.caption2).foregroundStyle(VesperTheme.muted)
            }
        }
    }
}
struct MemoryDetailView: View {
    @EnvironmentObject private var store: AppStore
    let memory: JSONValue
    @State private var detail: JSONValue = .null
    @State private var editing = false
    @State private var replacement = ""
    @State private var reason = ""
    @State private var busy = false
    @State private var error = ""
    private var current: JSONValue { detail["memory"] == .null ? memory : detail["memory"] }
    var body: some View {
        ZStack { Background(); Page(title: "Memory") {
            MemoryCard(memory: current)
            Text("Source: " + current["source"].string).font(.caption)
            Text("Recorded: " + current["createdAt"].string).font(.caption)
            Text("Recalled \(Int(current["surfaceCount"].number)) times").font(.caption)
            Text(current["confidence"] == .null ? "Confidence: not recorded" : "Confidence: \(Int(current["confidence"].number * 100))%").font(.caption)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Correct") { replacement = current["body"].string; editing = true }
                Button(current["pinned"].bool ? "Unpin" : "Pin") { Task { await update("pin", extra: ["pinned": .bool(!current["pinned"].bool)]) } }
                Button(current["demotedAt"] == .null ? "Make historical" : "Restore") { Task { await update(current["demotedAt"] == .null ? "demote" : "restore") } }
            }.buttonStyle(.bordered).disabled(busy)
            if current["reviewStatus"].string == "candidate" && current["type"].string == "core" { Button("Confirm this fact") { Task { await update("approve_core") } }.disabled(busy) }
            Text("Original evidence").font(.headline)
            if detail["evidence"].array.isEmpty { Text("No original source was linked to this memory.").font(.caption).foregroundStyle(VesperTheme.muted) }
            ForEach(detail["evidence"].array) { source in NavigationLink { EvidenceView(evidence: source) } label: { Label(String(source["content"].string.prefix(90)), systemImage: "doc.text.magnifyingglass") } }
            Text("Version history").font(.headline)
            ForEach(detail["revisions"].array) { revision in
                GlassCard { VStack(alignment: .leading, spacing: 8) {
                    Text(revision["body"].string).textSelection(.enabled)
                    Text(revision["reason"].string).font(.caption)
                    Text(revision["createdAt"].string + " · " + revision["action"].string).font(.caption2).foregroundStyle(VesperTheme.muted)
                } }
            }
        } }.navigationBarTitleDisplayMode(.inline).task { await load() }
        .sheet(isPresented: $editing) {
            EditorSheet(title: "Correct memory", busy: busy, save: { Task {
                await update(current["type"].string == "core" ? "correct_core" : "correct", extra: ["body": .string(replacement), "reason": .string(reason), "tags": current["tags"], "mood": current["mood"]])
                if error.isEmpty { editing = false }
            } }) { FormField(label: "Current fact", text: $replacement, multiline: true); FormField(label: "Why this changed", text: $reason); if !error.isEmpty { Text(error).foregroundStyle(.red) } }
        }
    }
    private func load() async {
        do { var q = URLComponents(); q.queryItems = [URLQueryItem(name: "id", value: memory.id)]; detail = try await store.api.request("/api/memory?" + (q.percentEncodedQuery ?? "")); error = "" }
        catch { self.error = error.localizedDescription }
    }
    private func update(_ action: String, extra: [String: JSONValue] = [:]) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { var body = extra; body["id"] = .string(memory.id); body["action"] = .string(action); _ = try await store.api.request("/api/memory", method: "PATCH", body: .object(body)); await load() }
        catch { self.error = error.localizedDescription }
    }
}
struct EvidenceView: View {
    let evidence: JSONValue
    var body: some View {
        ZStack { Background(); Page(title: "Original source") {
            Text(evidence["createdAt"].string).font(.caption)
            Text(evidence["content"].string).textSelection(.enabled)
            ForEach(Array(evidence["attachments"].array.enumerated()), id: \.offset) { _, attachment in
                if let url = URL(string: attachment["url"].string), url.scheme == "https" { Link(attachment["name"].string.isEmpty ? "Open attachment" : attachment["name"].string, destination: url) }
            }
            Text("Conversation: " + evidence["conversationId"].string).font(.caption).textSelection(.enabled)
            if evidence["conversationId"].string != "manual-memory" { Button("Open original conversation") { NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: ["conversationId": evidence["conversationId"].string, "messageId": evidence["messageId"].string]) } }
        } }.navigationBarTitleDisplayMode(.inline)
    }
}
private struct MemoryRelations: View {
    let items: [JSONValue]
    @State private var tag = ""
    private var tags: [String] { Array(Set(items.flatMap { $0["tags"].array.map(\.string) })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connections through saved people, places and topics").font(.caption).foregroundStyle(VesperTheme.muted)
            if !tags.isEmpty { MemoryRelationGraph(items: items) }
            if tags.isEmpty { EmptyCard(title: "No connections yet", message: "Add people, places or topics to a memory to connect its records.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                ForEach(tags, id: \.self) { value in Button { tag = value } label: { Text(value).padding(12).frame(maxWidth: .infinity).background(tag == value ? VesperTheme.accent.opacity(0.3) : VesperTheme.surface, in: Capsule()) }.buttonStyle(.plain) }
            }
            if !tag.isEmpty {
                ForEach(items.filter { $0["tags"].array.contains(.string(tag)) }) { item in
                    NavigationLink { MemoryDetailView(memory: item) } label: { HStack { Image(systemName: "link"); MemoryCard(memory: item) } }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MemoryRelationGraph: View {
    let items: [JSONValue]
    @State private var selected: JSONValue?
    private var records: [JSONValue] { Array(items.filter { !$0["tags"].array.isEmpty }.prefix(10)) }
    private var topics: [String] { Array(Set(records.flatMap { $0["tags"].array.map(\.string) })).sorted().prefix(8).map { $0 } }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    for (i, memory) in records.enumerated() {
                        for (j, topic) in topics.enumerated() where memory["tags"].array.contains(.string(topic)) {
                            var edge = Path(); edge.move(to: point(i, count: records.count, outer: true, size: size)); edge.addLine(to: point(j, count: topics.count, outer: false, size: size))
                            context.stroke(edge, with: .color(VesperTheme.accent.opacity(0.35)), lineWidth: 1)
                        }
                    }
                }
                ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                    Text(topic).font(.caption2).lineLimit(2).padding(7).background(.regularMaterial, in: Capsule())
                        .position(point(index, count: topics.count, outer: false, size: geometry.size))
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, memory in
                    Button { selected = memory } label: {
                        Image(systemName: "doc.text").frame(width: 38, height: 38).background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(VesperTheme.accent.opacity(0.5)))
                    }.accessibilityLabel(memory["body"].string).position(point(index, count: records.count, outer: true, size: geometry.size))
                }
            }
        }.frame(height: 320)
        .sheet(item: $selected) { item in NavigationStack { MemoryDetailView(memory: item).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } } } }
    }
    private func point(_ index: Int, count: Int, outer: Bool, size: CGSize) -> CGPoint {
        let angle = Double(index) / Double(max(1, count)) * 2 * Double.pi - Double.pi / 2
        let radius = min(size.width / 2 - 24, 138) * (outer ? 1 : 0.47)
        return CGPoint(x: size.width/2 + cos(angle)*radius, y: size.height/2 + sin(angle)*radius)
    }
}
