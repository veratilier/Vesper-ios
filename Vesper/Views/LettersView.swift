import SwiftUI

struct LettersView: View {
    @EnvironmentObject private var app: AppStore
    @AppStorage("vesperPalette") private var palette = VesperPalette.blue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = LettersStore()
    @ObservedObject private var notificationRoute = LetterNotificationRoute.shared
    var initialSelection: String? = nil
    @State private var screen = "archive"
    @State private var filter = "All"
    @AppStorage("vesperLetterMailbox") private var mailbox = "Vera"
    @State private var hoverID: String?
    @State private var selectedID: String?
    @State private var page = 0
    @State private var opened: VesperLetter?
    @State private var sealed: VesperLetter?
    @State private var delivered = false
    @State private var archiveVisible = false
    private var colors: LetterColors { LetterColors(palette: VesperPalette(rawValue: palette) ?? .white) }
    private var title: String { screen == "compose" ? "Write a letter" : screen == "read" ? "From " + (opened?.author ?? "Rowan") : mailbox + "’s mailbox" }
    private var filed: [VesperLetter] {
        model.letters.filter { !model.upcoming($0) && $0.matchesMailbox(mailbox, filter: filter) }
    }
    private var visible: [VesperLetter] { Array(filed.dropFirst(page * 5).prefix(5)) }
    private var selected: VesperLetter? { visible.first { $0.id == selectedID } }
    private var archiveLabel: String {
        guard let created = visible.first?.createdAt, let date = LetterDates.parse(created) else { return "Your letters" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    private var pageContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    if screen != "archive" { Button { screen = "archive"; delivered = false } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back to letters") }
                    else {
                        Menu {
                            Button("Vera’s mailbox") { mailbox = "Vera" }
                            Button("Rowan’s mailbox") { mailbox = "Rowan" }
                        } label: {
                            Image(systemName: "tray.2").frame(width: 44, height: 44).vesperGlass(in: Circle(), interactive: true)
                        }.accessibilityLabel("Switch mailbox").accessibilityIdentifier("switch-letter-mailbox")
                    }
                    Spacer()
                    if screen == "archive" { Button { screen = "compose" } label: { Label("Write", systemImage: "square.and.pencil") } }
                    if screen == "compose" { Button("Save draft") { model.saveDraft(); screen = "archive" } }
                }.font(.custom("Georgia", size: 14))
                if !model.status.isEmpty { Text(model.status).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.updatesFrequently) }
                switch screen {
                case "compose": compose
                case "post": posting
                case "read": reading
                default: archive
                }
            }.padding(.horizontal, 22).padding(.bottom, 24).foregroundStyle(colors.ink)
        }.refreshable { await model.load() }
            .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
            .toolbar { ToolbarItem(placement: .principal) { Text(title).font(.custom("Georgia", size: 24)) } }
    }
    private var observedContent: some View {
        pageContent
            .task(id: app.baseURL + "\n" + app.token) {
                model.configure(app.api); screen = "archive"; opened = nil; sealed = nil; selectedID = nil; hoverID = nil; page = 0
                await model.load()
                if let letter = model.letters.first(where: { $0.id == initialSelection }) { mailbox = letter.readerName }
                selectedID = initialSelection
                await openNotificationLetter()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if phase == .active && screen == "archive" { await model.load() }
                }
            }
            .onChange(of: notificationRoute.letterID) { _, _ in Task { await openNotificationLetter() } }
            .onChange(of: phase) { _, next in if next == .active { Task { await model.load() } } }
            .onAppear { archiveVisible = true; markArrivalsSeen(); Task { await model.load() } }
            .onDisappear { archiveVisible = false }
            .onChange(of: model.letters) { _, _ in
                markArrivalsSeen()
                if let id = opened?.id, let updated = model.letters.first(where: { $0.id == id }) { opened = updated }
            }
            .onReceive(LetterInbox.shared.$covers) { _ in markArrivalsSeen() }
            .onChange(of: model.draft) { _, _ in model.saveDraft(showStatus: false) }
            .onChange(of: screen) { _, _ in markArrivalsSeen() }
            .onChange(of: filter) { _, _ in resetSelection() }
            .onChange(of: mailbox) { _, _ in filter = "All"; sealed = nil; resetSelection(); markArrivalsSeen() }
            .onChange(of: filed.map(\.id)) { _, _ in if page * 5 >= filed.count { resetSelection() } }
    }
    var body: some View {
        observedContent
            .sheet(item: $sealed) { letter in
                VStack(spacing: 24) {
                    LetterEnvelope(colors: colors, author: letter.author).frame(width: 245, height: 150)
                    Text(letter.displayTitle).font(.system(size: 23, design: .serif))
                    if let date = letter.unlockAt { Text("Opens " + LetterDates.display(date)).font(.system(size: 15, design: .serif)) }
                    if !letter.isLocked { Button("Read your copy") { sealed = nil; open(letter) } }
                    Button("Back to Letters") { sealed = nil }
                }.padding(30).foregroundStyle(colors.ink).presentationDetents([.medium]).presentationBackground(colors.paper)
            }
    }
    @ViewBuilder private var selectionBar: some View {
        if screen == "archive", let selected {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selected.displayTitle).font(.custom("Georgia", size: 16)).lineLimit(1)
                    Text(selected.author + " · " + LetterDates.display(selected.createdAt)).font(.custom("Georgia", size: 11)).opacity(0.65).lineLimit(1)
                    letterStatus(selected)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { open(selected) } label: {
                    Text("Open").font(.custom("Georgia", size: 16)).padding(.horizontal, 20).frame(minHeight: 44)
                        .foregroundStyle(colors.ink).vesperGlass(in: Capsule(), interactive: true)
                }.buttonStyle(.plain).disabled(model.saving).accessibilityIdentifier("open-selected-letter")
            }.foregroundStyle(colors.ink).padding(14).vesperGlass(in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 22).padding(.bottom, 8)
        }
    }
    private var archive: some View {
        VStack(spacing: 16) {
            Picker("Letters filter", selection: $filter) { ForEach(["All", "Unread", "Kept"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            let upcoming = model.letters.filter { model.upcoming($0) && $0.matchesMailbox(mailbox, filter: filter) }
            if !upcoming.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(upcoming) { letter in
                            Button { sealed = letter } label: {
                                HStack(spacing: 12) {
                                    LetterEnvelope(colors: colors, author: letter.author).frame(width: 65, height: 42)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Upcoming").font(.custom("Georgia", size: 11)).opacity(0.6)
                                        Text(letter.displayTitle).font(.custom("Georgia", size: 15)).lineLimit(1)
                                        Text("Opens " + LetterDates.display(letter.unlockAt ?? "")).font(.custom("Georgia", size: 11)).opacity(0.7)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "lock").font(.caption)
                                }.padding(12).frame(minHeight: 78).containerRelativeFrame(.horizontal).vesperGlass(in: RoundedRectangle(cornerRadius: 15))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "envelope").font(.system(size: 24, weight: .light)).opacity(0.4).frame(width: 65, height: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Upcoming").font(.custom("Georgia", size: 11)).opacity(0.6)
                        Text("Nothing waiting here").font(.custom("Georgia", size: 15)).opacity(0.6)
                    }
                    Spacer(minLength: 0)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                    .vesperGlass(in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(colors.line.opacity(0.25)))
                    .accessibilityIdentifier("empty-upcoming-letters")
            }
            HStack { Text(archiveLabel).font(.custom("Georgia", size: 14)); Spacer(); Text("\(visible.count) / \(filed.count)").font(.custom("Georgia", size: 12)).opacity(0.6) }
            if filed.isEmpty { Text(model.loading ? "Opening your letters…" : "Letters will find their place here.").font(.system(size: 15, design: .serif)).padding(.vertical, 12) }
            else { LetterStack(letters: visible, hoverID: $hoverID, selectedID: $selectedID, colors: colors) }
            if selected == nil, let preview = visible.first(where: { $0.id == hoverID }) ?? visible.first {
                letterStatus(preview).frame(maxWidth: .infinity, alignment: .leading)
            }
            if selected == nil && !filed.isEmpty { Text("Brush across the letters. Hold one to choose.").font(.custom("Georgia", size: 12)).opacity(0.65).frame(maxWidth: .infinity, alignment: .leading) }
            if filed.count > 5 {
                HStack {
                    Button("Previous") { page -= 1; selectedID = nil; hoverID = nil }.disabled(page == 0)
                    Spacer(); Text("\(page + 1) / \(max(1, (filed.count + 4) / 5))").font(.caption); Spacer()
                    Button("Next") { page += 1; selectedID = nil; hoverID = nil }.disabled((page + 1) * 5 >= filed.count)
                }.font(.system(size: 13, design: .serif))
            }
            if !model.cursor.isEmpty { Button("Load earlier letters") { Task { await model.load(reset: false) } }.disabled(model.loading) }
        }
    }
    private var compose: some View {
        VStack(spacing: 18) {
            Text("To  Rowan").font(.system(size: 16, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 20) {
                TextField("A title, if you like", text: $model.draft.title).font(.system(size: 20, design: .serif))
                Text("Dear Rowan,").font(.system(size: 20, design: .serif))
                TextEditor(text: $model.draft.text).scrollContentBackground(.hidden).frame(minHeight: 230).font(.system(size: 17, design: .serif)).background(.clear).accessibilityLabel("Letter body")
                Text("Vera").font(VesperTheme.title(40)).frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(24).vesperGlass(in: RoundedRectangle(cornerRadius: 16)).disabled(model.draft.deliveryAttempted)
            Toggle("Open on a date", isOn: $model.draft.scheduled).disabled(model.draft.deliveryAttempted)
            if model.draft.scheduled { DatePicker("Opens", selection: $model.draft.unlockAt).disabled(model.draft.deliveryAttempted) }
            if model.draft.deliveryAttempted { Text("Delivery has already been attempted. Retry the same sealed letter to confirm it.").font(.footnote) }
            action(model.draft.deliveryAttempted ? "Retry delivery" : "Seal & send") { screen = "post"; delivered = false; model.saveDraft() }
                .disabled(model.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var posting: some View {
        VStack(spacing: 16) {
            LetterPostbox(colors: colors, delivered: delivered)
            Text(delivered ? "Delivered" : "Ready for delivery").font(.system(size: 19, design: .serif))
            Text("✧").foregroundStyle(colors.line)
            action(delivered ? "Back to Letters" : model.saving ? "Posting…" : "Post letter") {
                if delivered { screen = "archive"; delivered = false; return }
                Task {
                    if await model.post() != nil { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.9)) { delivered = true } }
                }
            }.disabled(model.saving)
            if !delivered { Button("Edit letter") { screen = "compose" }.disabled(model.saving || model.draft.deliveryAttempted) }
        }
    }
    private var reading: some View {
        VStack(spacing: 20) {
            if let letter = opened {
                VStack(alignment: .leading, spacing: 22) {
                    Text(letter.displayTitle).font(.system(size: 23, design: .serif)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    Text(LetterDates.display(letter.createdAt)).font(.system(size: 12, design: .serif)).opacity(0.65).frame(maxWidth: .infinity)
                    letterStatus(letter).frame(maxWidth: .infinity, alignment: .center)
                    Divider(); Text("Dear " + (letter.recipient ?? (letter.author == "Vera" ? "Rowan" : "Vera")) + ",").font(.system(size: 17, design: .serif))
                    Text(letter.text ?? "").font(.system(size: 17, design: .serif)).lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text(letter.author).font(VesperTheme.title(40)).frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(25).frame(minHeight: 420).vesperGlass(in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 12) {
                    if letter.readerName == "Vera" {
                        action("Reply") { if model.reply(to: letter) { screen = "compose" } }
                        Button(letter.kept == true ? "Kept" : "Keep") { Task { if let updated = await model.keep(letter) { opened = updated } } }.frame(maxWidth: .infinity).padding(14).overlay(Capsule().stroke(colors.line)).disabled(model.saving)
                    } else {
                        Text("Your copy · Rowan’s read and kept status updates separately").font(.footnote).foregroundStyle(colors.ink.opacity(0.65))
                    }
                }
            }
        }
    }
    private func letterStatus(_ letter: VesperLetter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(letter.readLabel, systemImage: letter.readerRead == true ? "envelope.open" : "envelope")
            if !letter.keepLabels.isEmpty { Label(letter.keepLabels.joined(separator: " · "), systemImage: "bookmark.fill") }
        }.font(.custom("Georgia", size: 12)).foregroundStyle(colors.ink.opacity(0.75))
    }
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title).font(.system(size: 17, design: .serif)).foregroundStyle(colors.ink).frame(maxWidth: .infinity).padding(15).vesperGlass(in: Capsule(), interactive: true) }.buttonStyle(.plain)
    }
    private func resetSelection() { page = 0; hoverID = nil; selectedID = nil }
    private func markArrivalsSeen() {
        if archiveVisible, screen == "archive", mailbox == "Vera", phase == .active { LetterInbox.shared.markArrivalSeen(model.letters.filter { $0.readerName == "Vera" }.map(\.id)) }
    }
    private func openNotificationLetter() async {
        guard let id = notificationRoute.letterID, model.configured else { return }
        if let letter = await model.open(id: id) {
            mailbox = letter.readerName; opened = letter; screen = "read"; notificationRoute.letterID = nil
        }
    }
    private func open(_ letter: VesperLetter) {
        Task { if let result = await model.open(letter) { opened = result; screen = "read" } }
    }
}
