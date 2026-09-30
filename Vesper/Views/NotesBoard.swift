import SwiftUI

struct NotePlacement: Equatable {
    var x: Double, y: Double, rotation: Double, scale: Double, zIndex: Double
    var cardStyle: String
    init(_ note: JSONValue, index: Int) {
        let layout = note["layout"]
        x = layout["x"] == .null ? Double(index % 3) * 250 + 140 : layout["x"].number
        y = layout["y"] == .null ? Double(index / 3) * 270 + 150 : layout["y"].number
        rotation = layout["rotation"] == .null ? Double(index % 5 - 2) * 2 : layout["rotation"].number
        scale = layout["scale"] == .null ? 1 : min(1.5, max(0.65, layout["scale"].number))
        zIndex = layout["zIndex"] == .null ? Double(index) : layout["zIndex"].number
        cardStyle = layout["cardStyle"].string.isEmpty ? (note["kind"].string == "agent" ? "letter" : "sticky") : layout["cardStyle"].string
    }
    var json: JSONValue { .object(["x": .number(x), "y": .number(y), "rotation": .number(rotation), "scale": .number(scale), "zIndex": .number(zIndex), "cardStyle": .string(cardStyle)]) }
}
struct NotesBoard: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: JSONValue?
    @State private var placements: [String: NotePlacement] = [:]
    @State private var pendingDelete: JSONValue?
    @State private var zoom = 1.0
    @State private var draggingID: String?
    @State private var pendingSaves: Set<String> = []
    private var notes: [JSONValue] { store.document("notes").array }
    private var canvasSize: CGSize {
        let all = notes.enumerated().map { placement($0.element, index: $0.offset) }
        return CGSize(width: max(850, (all.map(\.x).max() ?? 0) + 160), height: max(800, (all.map(\.y).max() ?? 0) + 180))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes").font(VesperTheme.title(34))
                Spacer()
                Button { zoom = max(0.5, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                Button { zoom = min(1.5, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
                Button { editing = .object(["id": .string(UUID().uuidString), "createdAt": .string(isoNow()), "kind": .string("user")]) } label: { Image(systemName: "plus") }.accessibilityLabel("New note")
            }.padding(20)
            Text("Tap to edit · hold and drag to arrange").font(.caption).foregroundStyle(VesperTheme.muted)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        let layout = placement(note, index: index)
                        BoardNote(note: note, layout: layout, zoom: zoom, lifting: { draggingID = $0 ? note.id : nil }, edit: { editing = note }, move: { delta in
                            var next = layout; next.x = max(125, layout.x + Double(delta.width)); next.y = max(135, layout.y + Double(delta.height))
                            next.zIndex = (placements.values.map(\.zIndex).max() ?? Double(notes.count)) + 1
                            save(note, placement: next)
                        })
                        .position(x: layout.x, y: layout.y).zIndex(draggingID == note.id ? 1_000_000 : layout.zIndex)
                        .contextMenu {
                            Button("Edit") { editing = note }
                            ForEach(["sticky", "letter", "grid", "polaroid", "tag"], id: \.self) { style in Button(style.capitalized) { var next = layout; next.cardStyle = style; save(note, placement: next) } }
                            Button("Rotate") { var next = layout; next.rotation = layout.rotation >= 8 ? -8 : layout.rotation + 4; save(note, placement: next) }
                            Button("Delete", role: .destructive) { pendingDelete = note }
                        }
                    }
                }.frame(width: canvasSize.width, height: canvasSize.height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
            }
        }.onChange(of: store.document("notes")) { _, document in
            for (index, note) in document.array.enumerated() where !pendingSaves.contains(note.id) && draggingID != note.id {
                placements[note.id] = NotePlacement(note, index: index)
            }
        }.sheet(item: $editing) { CollectionEditor(kind: .notes, item: $0) }
        .task { await store.refresh() }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let note = pendingDelete { Task { _ = await store.remove("notes", id: note.id); pendingDelete = nil } } }
        }
    }
    private func placement(_ note: JSONValue, index: Int) -> NotePlacement { placements[note.id] ?? NotePlacement(note, index: index) }
    private func save(_ note: JSONValue, placement: NotePlacement) {
        let previous = placements[note.id]; placements[note.id] = placement; pendingSaves.insert(note.id)
        Task {
            let ok = await store.mutate("notes") { document in
                var items = document.array
                guard let index = items.firstIndex(where: { $0.id == note.id }) else { throw ServiceError(message: "This note was removed. Refresh the board.") }
                // The body and all unknown fields come from the latest server copy.
                items[index]["layout"] = placement.json
                return .array(items)
            }
            if placements[note.id] == placement { pendingSaves.remove(note.id); if !ok { placements[note.id] = previous } }
        }
    }
}
private struct BoardNote: View {
    let note: JSONValue
    let layout: NotePlacement
    let zoom: Double
    let lifting: (Bool) -> Void
    let edit: () -> Void
    let move: (CGSize) -> Void
    @GestureState private var dragging: CGSize = .zero
    @GestureState private var lifted = false
    private var paper: Color { layout.cardStyle == "sticky" ? Color(red: 1, green: 0.96, blue: 0.73) : Color(red: 0.95, green: 0.98, blue: 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: layout.cardStyle == "tag" ? "pin.fill" : "paperclip"); Spacer(); Text(note["kind"].string == "agent" ? "Rowan" : "Vera").font(.caption) }
            if layout.cardStyle == "polaroid", !note["image"].string.isEmpty { Artwork(url: note["image"].string).frame(height: 105).clipped() }
            Text(note["text"].string.isEmpty ? "A new note" : note["text"].string).font(.system(size: 16, design: layout.cardStyle == "grid" ? .monospaced : .serif)).lineSpacing(5).lineLimit(layout.cardStyle == "tag" ? 4 : 8)
            Spacer(minLength: 0)
        }.padding(20).frame(width: 220, height: layout.cardStyle == "tag" ? 165 : 230)
        .foregroundStyle(Color(red: 0.16, green: 0.23, blue: 0.27))
        .background(paper, in: RoundedRectangle(cornerRadius: layout.cardStyle == "tag" ? 20 : 3))
        .overlay { if layout.cardStyle == "grid" { Canvas { context, size in
            for x in stride(from: CGFloat(0), to: size.width, by: 16) { for y in stride(from: CGFloat(0), to: size.height, by: 16) {
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.blue.opacity(0.16)))
            } }
        }.allowsHitTesting(false) } }
        .shadow(color: .black.opacity(lifted ? 0.25 : 0.12), radius: lifted ? 18 : 4, x: 2, y: lifted ? 12 : 5)
        .rotationEffect(.degrees(layout.rotation))
        .scaleEffect(layout.scale * (lifted ? 1.035 : 1))
        .offset(x: dragging.width / zoom, y: dragging.height / zoom)
        .onChange(of: lifted) { _, active in lifting(active) }
        .onTapGesture(perform: edit)
        .gesture(LongPressGesture(minimumDuration: 0.3).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($lifted) { value, state, _ in if case .second(true, _) = value { state = true } }
            .updating($dragging) { value, state, _ in if case .second(true, let drag?) = value { state = drag.translation } }
            .onEnded { value in if case .second(true, let drag?) = value { move(CGSize(width: drag.translation.width / zoom, height: drag.translation.height / zoom)) } })
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Edit")) { edit() }
    }
}
