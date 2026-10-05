import SwiftUI

struct LetterColors {
    var palette: VesperPalette
    var paper: Color { palette == .black ? Color(white: 0.16) : palette == .blue ? Color(red: 0.91, green: 0.95, blue: 0.97) : Color(white: 0.98) }
    var shade: Color { palette == .black ? Color(white: 0.09) : palette == .blue ? Color(red: 0.65, green: 0.77, blue: 0.82) : Color(white: 0.82) }
    var metal: [Color] { palette == .black ? [Color(white: 0.17), Color(white: 0.44), Color(white: 0.24), Color(white: 0.11)] : palette == .blue ? [Color(red: 0.50, green: 0.67, blue: 0.74), Color(white: 0.96), Color(red: 0.73, green: 0.83, blue: 0.87), Color(red: 0.46, green: 0.62, blue: 0.69)] : [Color(white: 0.67), Color(white: 0.99), Color(white: 0.85), Color(white: 0.59)] }
    var ink: Color { palette.ink }
    var line: Color { palette == .black ? Color(white: 0.48) : palette == .blue ? Color(red: 0.60, green: 0.70, blue: 0.75) : Color(white: 0.72) }
    var fold: Color { palette == .black ? Color(white: 0.12) : palette == .blue ? Color(red: 0.84, green: 0.90, blue: 0.93) : Color(white: 0.92) }
}
struct LetterFlap: Shape {
    func path(in rect: CGRect) -> Path { Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: rect.width, y: 0)); p.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.64)); p.closeSubpath() } }
}
struct LetterPocket: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.height)); p.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.48))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height)); p.closeSubpath()
        }
    }
}
struct LetterEnvelope: View {
    let colors: LetterColors
    var title = ""
    var author = "Vera"
    var showTitle = false
    var recipient: String?
    var showSeal = true
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [colors.paper, colors.fold], startPoint: .topLeading, endPoint: .bottomTrailing))
                LetterPocket().fill(LinearGradient(colors: [colors.paper.opacity(0.35), colors.fold.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .overlay(LetterPocket().stroke(colors.line.opacity(0.25), lineWidth: 0.6))
                LetterFlap().fill(LinearGradient(colors: [colors.paper, colors.fold], startPoint: .top, endPoint: .bottom)).shadow(color: .black.opacity(0.13), radius: 1, y: 2)
                Image("LetterPaper").resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                    .saturation(0).opacity(0.12).blendMode(.multiply).accessibilityHidden(true)
                if showTitle {
                    VStack(spacing: 6) {
                        Text(title).font(.custom("Georgia-Italic", size: 14)).lineLimit(2)
                        if let recipient { Text("To " + recipient).font(.custom("Georgia-Italic", size: 12)).opacity(0.8) }
                    }.multilineTextAlignment(.center).padding(.horizontal, 15).padding(.top, showSeal ? 15 : g.size.height * 0.26).foregroundStyle(colors.ink)
                }
                if showSeal { Text(String(author.prefix(1))).font(.system(size: g.size.width < 100 ? 13 : 24, design: .serif)).italic()
                    .foregroundStyle(colors.ink.opacity(0.7)).frame(width: g.size.width < 100 ? 20 : 36, height: g.size.width < 100 ? 20 : 36)
                    .background(LinearGradient(colors: colors.metal, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .overlay(Circle().stroke(colors.line, lineWidth: 2)).overlay(Circle().inset(by: 4).stroke(colors.line.opacity(0.5), lineWidth: 0.5))
                    .position(x: g.size.width * 0.5, y: g.size.height * 0.63)
                }
            }.compositingGroup().frame(width: g.size.width, height: g.size.height, alignment: .top)
                .overlay(Rectangle().stroke(colors.line.opacity(0.6), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.13), radius: 4, y: 4)
        }.accessibilityHidden(true)
    }
}
struct LetterStack: View {
    let letters: [VesperLetter]
    @Binding var hoverID: String?
    @Binding var selectedID: String?
    let colors: LetterColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holding: Task<Void, Never>?
    @State private var lastPoint: CGPoint?
    @State private var touching = false
    private var visible: [VesperLetter] { Array(letters.prefix(5)) }
    private var canvasHeight: CGFloat { visible.isEmpty ? 0 : visible.count == 1 ? 250 : 320 }
    private var frontTop: CGFloat { 40 + CGFloat(max(0, visible.count - 1)) * 18 }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: g.size.width, height: canvasHeight)
                ForEach(Array(visible.enumerated()), id: \.element.id) { slot, letter in
                    envelope(letter, slot: slot, width: g.size.width)
                }
            }.frame(width: g.size.width, height: canvasHeight, alignment: .topLeading).contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in sweep(value.location) }.onEnded { _ in
                    touching = false; holding?.cancel(); lastPoint = nil
                    if selectedID == nil { withAnimation(motion) { hoverID = nil } }
                })
        }.frame(height: canvasHeight).onDisappear { holding?.cancel(); touching = false }
    }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
    private func envelope(_ letter: VesperLetter, slot: Int, width: CGFloat) -> some View {
        let front = hoverID == letter.id || selectedID == letter.id
        let cardWidth = min(width * 0.84, 320)
        let base = frontTop - CGFloat(slot) * 18
        let lift: CGFloat = selectedID == letter.id ? 24 : hoverID == letter.id ? 18 : 0
        let restingAngle = [1.5, -1.0, 1.2, -1.6, -2.0][slot]
        return Button { selectedID = letter.id; hoverID = letter.id } label: {
            LetterEnvelope(colors: colors, title: letter.displayTitle, author: letter.author, showTitle: front || slot == 0,
                recipient: letter.recipient ?? (letter.author == "Vera" ? "Rowan" : "Vera"), showSeal: false)
                .overlay(alignment: .topTrailing) {
                    Text(LetterDates.parse(letter.createdAt)?.formatted(.dateTime.month(.abbreviated).day()) ?? "Letter")
                        .font(.custom("Georgia", size: 11)).padding(.horizontal, 10).padding(.vertical, 3)
                        .vesperGlass(in: UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).stroke(colors.line.opacity(0.75), lineWidth: 0.8))
                        .offset(x: -9, y: -2)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        Text(letter.readLabel)
                        if letter.isKept { Image(systemName: "bookmark.fill") }
                    }.font(.custom("Georgia", size: 10)).foregroundStyle(colors.ink)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .vesperGlass(in: Capsule())
                        .overlay(Capsule().stroke(colors.line.opacity(0.4), lineWidth: 0.5)).padding(8)
                }
        }.buttonStyle(.plain).frame(width: cardWidth, height: cardWidth / 1.7)
            .rotationEffect(.degrees(front ? -3 : restingAngle), anchor: .bottom)
            .offset(x: (width - cardWidth) / 2 + (slot.isMultiple(of: 2) ? -2 : 2), y: base - lift)
            .zIndex(front ? 100 : Double(90 - slot)).animation(motion, value: front).animation(motion, value: selectedID)
            .accessibilityLabel(([letter.displayTitle, letter.author, letter.readLabel] + letter.keepLabels).joined(separator: ", ")).accessibilityAddTraits(selectedID == letter.id ? .isSelected : [])
    }
    private func sweep(_ point: CGPoint) {
        guard !visible.isEmpty else { return }
        let slot = min(visible.count - 1, max(0, Int(((frontTop - point.y) / 18).rounded())))
        let candidate = visible[slot].id
        let moved = lastPoint.map { hypot($0.x - point.x, $0.y - point.y) > 7 } ?? true
        let changed = candidate != hoverID
        touching = true
        if changed { withAnimation(motion) { hoverID = candidate; selectedID = nil } }
        if changed || moved {
            lastPoint = point; holding?.cancel()
            holding = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard touching, !Task.isCancelled, hoverID == candidate else { return }
                withAnimation(motion) { selectedID = candidate }
            }
        }
    }
}
struct LetterPostbox: View {
    let colors: LetterColors
    var delivered = false
    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(LinearGradient(colors: colors.metal, startPoint: .leading, endPoint: .trailing)).frame(width: 42, height: 74).offset(y: 233)
            Ellipse().fill(LinearGradient(colors: colors.metal, startPoint: .top, endPoint: .bottom)).overlay(Ellipse().stroke(colors.line, lineWidth: 1)).frame(width: 120, height: 18).offset(y: 301)
            UnevenRoundedRectangle(topLeadingRadius: 89, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 89)
                .fill(LinearGradient(colors: colors.metal, startPoint: .leading, endPoint: .trailing)).overlay(UnevenRoundedRectangle(topLeadingRadius: 89, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 89).stroke(colors.line, lineWidth: 1))
                .frame(width: 180, height: 235).shadow(color: .black.opacity(0.18), radius: 12, x: 8, y: 10)
            Capsule().fill(LinearGradient(colors: colors.metal, startPoint: .leading, endPoint: .trailing)).frame(width: 20, height: 17).offset(y: -10)
            UnevenRoundedRectangle(topLeadingRadius: 78, topTrailingRadius: 78).stroke(colors.line.opacity(0.6), lineWidth: 2).frame(width: 165, height: 75).offset(y: 8)
            Text("LETTERS").font(.system(size: 10, design: .serif)).tracking(3).foregroundStyle(colors.ink.opacity(0.65)).offset(y: 58)
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.85)).overlay(RoundedRectangle(cornerRadius: 3).stroke(colors.line, lineWidth: 3)).frame(width: 128, height: 14).offset(y: 85)
            RoundedRectangle(cornerRadius: 30).stroke(colors.line.opacity(0.6), lineWidth: 1).frame(width: 145, height: 105).offset(y: 111)
            Text("RV").font(.system(size: 28, design: .serif)).italic().foregroundStyle(colors.ink.opacity(0.65)).frame(width: 55, height: 62).background(LinearGradient(colors: colors.metal, startPoint: .topLeading, endPoint: .bottomTrailing), in: Ellipse()).overlay(Ellipse().stroke(colors.line, lineWidth: 2)).offset(y: 133)
            Image(systemName: "keyhole").font(.system(size: 12)).foregroundStyle(colors.ink.opacity(0.65)).offset(y: 202)
            RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: colors.metal, startPoint: .top, endPoint: .bottom)).overlay(RoundedRectangle(cornerRadius: 3).stroke(colors.line, lineWidth: 1)).frame(width: 188, height: 11).offset(y: 232)
            LetterEnvelope(colors: colors).frame(width: 185, height: 106).rotationEffect(.degrees(delivered ? -4 : 0))
                .scaleEffect(delivered ? 0.18 : 1).offset(y: delivered ? 44 : 290).opacity(delivered ? 0 : 1)
        }.frame(maxWidth: .infinity).frame(height: 410).padding(.top, 15).accessibilityLabel("Letters mailbox")
    }
}
