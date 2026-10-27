import SwiftUI
import UIKit

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
    private var title: String { screen == "compose" ? "Write a letter" : app.personDisplayName(mailbox) + "’s mailbox" }
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
                            Button(app.agentDisplayName + "’s mailbox") { mailbox = "Rowan" }
                        } label: {
                            Image(systemName: "tray.2").frame(width: 44, height: 44).vesperMaterial(.thinMaterial, in: Circle())
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
            .toolbar {
                if screen != "read" {
                    ToolbarItem(placement: .principal) { Text(title).font(.custom("Georgia", size: 24)) }
                }
            }
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
                    Text(app.personDisplayName(selected.author) + " · " + LetterDates.display(selected.createdAt)).font(.custom("Georgia", size: 11)).opacity(0.65).lineLimit(1)
                    letterStatus(selected)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { open(selected) } label: {
                    Text("Open").font(.custom("Georgia", size: 16)).padding(.horizontal, 20).frame(minHeight: 44)
                        .foregroundStyle(colors.paper).background(colors.ink, in: Capsule())
                }.buttonStyle(.plain).disabled(model.saving).accessibilityIdentifier("open-selected-letter")
            }.foregroundStyle(colors.ink).padding(14).vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
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
                                }.padding(12).frame(minHeight: 78).containerRelativeFrame(.horizontal).background(colors.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(colors.line.opacity(0.35)))
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
                    .background(colors.paper.opacity(0.4), in: RoundedRectangle(cornerRadius: 15))
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
            Text("To  " + app.agentDisplayName).font(.system(size: 16, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 20) {
                TextField("A title, if you like", text: $model.draft.title).font(.system(size: 20, design: .serif))
                Text("Dear " + app.agentDisplayName + ",").font(.system(size: 20, design: .serif))
                TextEditor(text: $model.draft.text).scrollContentBackground(.hidden).frame(minHeight: 230).font(.system(size: 17, design: .serif)).background(.clear).accessibilityLabel("Letter body")
                Text("Vera").font(VesperTheme.title(40)).frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(24).background(colors.paper).overlay(Rectangle().stroke(colors.line.opacity(0.3))).shadow(color: .black.opacity(0.1), radius: 5, y: 4).disabled(model.draft.deliveryAttempted)
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
                LetterReadingPage(
                    letter: letter,
                    sender: app.personDisplayName(letter.author),
                    recipient: app.personDisplayName(letter.readerName),
                    colors: colors
                )
                letterStatus(letter).frame(maxWidth: 660, alignment: .leading)
                HStack(spacing: 12) {
                    if letter.readerName == "Vera" {
                        action("Reply") { if model.reply(to: letter) { screen = "compose" } }
                        Button(letter.kept == true ? "Kept" : "Keep") { Task { if let updated = await model.keep(letter) { opened = updated } } }.frame(maxWidth: .infinity).padding(14).overlay(Capsule().stroke(colors.line)).disabled(model.saving)
                    } else {
                        Text("Your copy · \(app.agentDisplayName)’s read and kept status updates separately").font(.footnote).foregroundStyle(colors.ink.opacity(0.65))
                    }
                }.frame(maxWidth: 660)
            }
        }
    }
    private func letterStatus(_ letter: VesperLetter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(app.personLabel(letter.readLabel), systemImage: letter.readerRead == true ? "envelope.open" : "envelope")
            if !letter.keepLabels.isEmpty { Label(app.personLabel(letter.keepLabels.joined(separator: " · ")), systemImage: "bookmark.fill") }
        }.font(.custom("Georgia", size: 12)).foregroundStyle(colors.ink.opacity(0.75))
    }
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title).font(.system(size: 17, design: .serif)).foregroundStyle(colors.paper).frame(maxWidth: .infinity).padding(15).background(colors.ink, in: Capsule()) }.buttonStyle(.plain)
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

private struct LetterReadingPage: View {
    let letter: VesperLetter
    let sender: String
    let recipient: String
    let colors: LetterColors
    private var paper: Color {
        colors.palette == .black ? colors.paper : Color(red: 0.998, green: 0.991, blue: 0.971)
    }
    private var ink: Color {
        colors.palette == .black ? colors.ink : Color(red: 0.29, green: 0.28, blue: 0.27)
    }
    private var rule: Color {
        colors.palette == .black ? .white.opacity(0.19) : Color(red: 0.78, green: 0.74, blue: 0.71).opacity(0.7)
    }
    private var parts: LetterReadingParts {
        LetterReadingParts(text: letter.text ?? "", sender: sender, author: letter.author)
    }
    private var date: String {
        guard let parsed = LetterDates.parse(letter.createdAt) else { return LetterDates.display(letter.createdAt) }
        return parsed.formatted(date: .long, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Text("VESPER LETTERS")
                    .font(.custom("Georgia", size: 10, relativeTo: .caption2))
                    .tracking(3.5).opacity(0.55)
                Text(letter.displayTitle)
                    .font(.system(size: 27, weight: .regular, design: .serif))
                    .multilineTextAlignment(.center)
                Text("To \(recipient)")
                    .font(.custom("Georgia", size: 13, relativeTo: .caption))
                    .opacity(0.65)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 34)

            if !parts.body.isEmpty {
                RuledLetterText(text: parts.body, ink: ink, rule: rule)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("letter-reading-body")
            }

            VStack(alignment: .trailing, spacing: 7) {
                Text(parts.signature ?? sender)
                    .font(.system(size: 18, weight: .regular, design: .serif))
                Text(date)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .opacity(0.66)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 43)

            if let postscript = parts.postscript {
                GeometryReader { size in
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: size.size.width, y: 0))
                    }.stroke(rule, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                }
                .frame(height: 1)
                .padding(.top, 35)
                Text(postscript)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(7)
                    .opacity(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 23)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 28).padding(.top, 42).padding(.bottom, 42)
        .frame(maxWidth: 660, minHeight: 510, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(paper)
                .overlay {
                    if colors.palette != .black {
                        Image("LetterPaper").resizable().scaledToFill().opacity(0.08).clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(colors.line.opacity(0.43), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("letter-reading-page")
    }
}

private struct LetterReadingParts {
    let body: String
    let signature: String?
    let postscript: String?

    init(text: String, sender: String, author: String) {
        var remaining = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var note: String?
        if let split = remaining.range(of: "\n\n", options: .backwards) {
            let finalParagraph = String(remaining[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = finalParagraph.lowercased()
            if ["ps:", "ps：", "p.s.:", "p.s.：", "附言:", "附言："].contains(where: { prefix.hasPrefix($0) }) {
                note = finalParagraph
                remaining = String(remaining[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var sign: String?
        if let lastBreak = remaining.lastIndex(of: "\n") {
            let lastLine = String(remaining[remaining.index(after: lastBreak)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if [sender, author].contains(where: { name in
                lastLine.count <= name.count + 16 && lastLine.lowercased().hasSuffix(name.lowercased())
            }) {
                sign = lastLine
                remaining = String(remaining[..<lastBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        body = remaining
        signature = sign
        postscript = note
    }
}

private struct RuledLetterText: UIViewRepresentable {
    let text: String
    let ink: Color
    let rule: Color

    final class Coordinator {
        var currentText = ""
        var currentInk: UIColor?
        var currentSizeCategory: UIContentSizeCategory?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RuledLetterContainer {
        RuledLetterContainer(frame: .zero)
    }

    func updateUIView(_ view: RuledLetterContainer, context: Context) {
        let inkColor = UIColor(ink)
        let category = view.traitCollection.preferredContentSizeCategory
        view.ruleColor = UIColor(rule)
        if context.coordinator.currentText != text || context.coordinator.currentInk?.isEqual(inkColor) != true || context.coordinator.currentSizeCategory != category {
            context.coordinator.currentText = text
            context.coordinator.currentInk = inkColor
            context.coordinator.currentSizeCategory = category
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16), compatibleWith: view.traitCollection)
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 25
            paragraph.lineSpacing = 15
            let styled = NSMutableAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: inkColor, .paragraphStyle: paragraph
            ])
            let firstLine = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if firstLine.count <= 24 && (firstLine.hasSuffix("：") || firstLine.hasSuffix(":")) {
                let greeting = paragraph.mutableCopy() as! NSMutableParagraphStyle
                greeting.firstLineHeadIndent = 0
                styled.addAttribute(.paragraphStyle, value: greeting,
                    range: NSRange(location: 0, length: min((text as NSString).length, (firstLine as NSString).length + 1)))
            }
            view.textView.attributedText = styled
            view.invalidateIntrinsicContentSize()
        }
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RuledLetterContainer, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured.height))
    }
}

private final class RuledLetterContainer: UIView {
    let textView = UITextView(frame: .zero, textContainer: nil)
    private let rules = CAShapeLayer()
    var ruleColor: UIColor = .clear {
        didSet { rules.strokeColor = ruleColor.cgColor; setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        rules.fillColor = nil
        rules.lineWidth = 0.7
        layer.addSublayer(rules)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.contentInset = .zero
        textView.isOpaque = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.dataDetectorTypes = []
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != bounds { textView.frame = bounds }
        textView.layoutIfNeeded()
        rules.frame = bounds
        let manager = textView.layoutManager
        manager.ensureLayout(for: textView.textContainer)
        let font = textView.attributedText.length > 0
            ? textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
        let baselineShift = font?.lineHeight ?? 20
        let path = UIBezierPath()
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { line, used, _, _, _ in
            let y = self.textView.textContainerInset.top - self.textView.contentOffset.y + max(used.maxY + 3, line.maxY - 5) + baselineShift
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: self.bounds.width, y: y))
        }
        rules.path = path.cgPath
    }
}
