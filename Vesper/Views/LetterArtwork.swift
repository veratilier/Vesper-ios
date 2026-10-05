import SwiftUI

struct LetterColors {
    var palette: VesperPalette
    var paper: Color { palette == .black ? Color(white: 0.16) : palette == .blue ? Color(red: 0.91, green: 0.95, blue: 0.97) : Color(red: 0.97, green: 0.95, blue: 0.90) }
    var shade: Color { palette == .black ? Color(white: 0.09) : palette == .blue ? Color(red: 0.65, green: 0.77, blue: 0.82) : Color(red: 0.82, green: 0.78, blue: 0.69) }
    var metal: [Color] { palette == .black ? [Color(white: 0.17), Color(white: 0.44), Color(white: 0.24), Color(white: 0.11)] : palette == .blue ? [Color(red: 0.50, green: 0.67, blue: 0.74), Color(white: 0.96), Color(red: 0.73, green: 0.83, blue: 0.87), Color(red: 0.46, green: 0.62, blue: 0.69)] : [Color(white: 0.67), Color(white: 0.99), Color(white: 0.85), Color(white: 0.59)] }
    var ink: Color { palette == .black ? Color(white: 0.92) : Color(red: 0.24, green: 0.23, blue: 0.20) }
    var line: Color { palette == .black ? Color(white: 0.48) : Color(red: 0.69, green: 0.68, blue: 0.62) }
}
struct LetterFlap: Shape {
    func path(in rect: CGRect) -> Path { Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: rect.width, y: 0)); p.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.64)); p.closeSubpath() } }
}
struct LetterEnvelope: View {
    let colors: LetterColors
    var title = ""
    var author = "Vera"
    var showTitle = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [colors.paper, colors.shade.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                LetterFlap().fill(LinearGradient(colors: [colors.paper, colors.shade], startPoint: .top, endPoint: .bottom)).shadow(color: .black.opacity(0.13), radius: 1, y: 2)
                if showTitle { Text(title).font(.system(size: 14, design: .serif)).italic().lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 10).padding(.top, 15).foregroundStyle(colors.ink) }
                Text(String(author.prefix(1))).font(.system(size: g.size.width < 100 ? 13 : 24, design: .serif)).italic()
                    .foregroundStyle(colors.ink.opacity(0.7)).frame(width: g.size.width < 100 ? 20 : 36, height: g.size.width < 100 ? 20 : 36)
                    .background(LinearGradient(colors: colors.metal, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .overlay(Circle().stroke(colors.line, lineWidth: 2)).overlay(Circle().inset(by: 4).stroke(colors.line.opacity(0.5), lineWidth: 0.5))
                    .offset(y: g.size.height * 0.63)
            }.overlay(Rectangle().stroke(colors.line.opacity(0.6), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.13), radius: 4, y: 4)
        }.accessibilityHidden(true)
    }
}
struct UprightLetters: View {
    let letters: [VesperLetter]
    @Binding var hoverID: String?
    @Binding var selectedID: String?
    let colors: LetterColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holding: Task<Void, Never>?
    @State private var lastPoint: CGPoint?
    @State private var touching = false
    private var visible: [VesperLetter] { Array(letters.prefix(5)) }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                // Offsets below use this full canvas as their origin, rather than
                // the smaller intrinsic bounds of the unpositioned box pieces.
                Color.clear.frame(width: g.size.width, height: 330)
                Ellipse().fill(.black.opacity(0.13)).blur(radius: 10).frame(width: g.size.width * 0.85, height: 28).offset(x: 12, y: 277)
                RoundedRectangle(cornerRadius: 5).fill(colors.shade).overlay(RoundedRectangle(cornerRadius: 5).stroke(colors.line, lineWidth: 1)).frame(width: g.size.width * 0.78, height: 144).rotationEffect(.degrees(-5)).offset(x: g.size.width * 0.16, y: 125)
                ForEach(Array(visible.enumerated()), id: \.element.id) { slot, letter in
                    envelope(letter, slot: slot, width: g.size.width)
                }
                Rectangle().fill(LinearGradient(colors: colors.metal, startPoint: .leading, endPoint: .trailing)).frame(width: g.size.width * 0.16, height: 137).rotationEffect(.degrees(-14)).offset(x: g.size.width * 0.80, y: 153).zIndex(101)
                HStack(spacing: 20) {
                    Text("RV").font(.system(size: 26, design: .serif)).italic()
                    Text("LETTERS TO KEEP").font(.system(size: 10, design: .serif)).tracking(1)
                }.foregroundStyle(colors.ink.opacity(0.45)).frame(width: g.size.width * 0.82, height: 57)
                    .background(LinearGradient(colors: [colors.paper, colors.shade], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(colors.line, lineWidth: 2)).rotationEffect(.degrees(5)).offset(x: g.size.width * 0.04, y: 248).zIndex(102)
            }.frame(width: g.size.width, height: 330, alignment: .topLeading).contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in sweep(value.location) }.onEnded { _ in
                    touching = false; holding?.cancel(); lastPoint = nil
                    if selectedID == nil { withAnimation(motion) { hoverID = nil } }
                })
        }.frame(height: 330).onDisappear { holding?.cancel(); touching = false }
    }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
    private func envelope(_ letter: VesperLetter, slot: Int, width: CGFloat) -> some View {
        let front = hoverID == letter.id || selectedID == letter.id
        let base = 170 - CGFloat(slot) * 15
        let lift: CGFloat = selectedID == letter.id ? 64 : hoverID == letter.id ? 42 : 0
        return Button { selectedID = letter.id; hoverID = letter.id } label: {
            LetterEnvelope(colors: colors, title: letter.displayTitle, author: letter.author, showTitle: front || slot == 0)
                .overlay(alignment: .topTrailing) { Text(LetterDates.parse(letter.createdAt)?.formatted(.dateTime.month(.abbreviated).day()) ?? "Letter").font(.system(size: 11, design: .serif)).padding(.horizontal, 10).padding(.vertical, 3).background(colors.paper, in: UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)).offset(x: -9, y: -20) }
        }.buttonStyle(.plain).frame(width: width * 0.75, height: 125)
            .rotationEffect(.degrees(front ? -5 : 1), anchor: .bottom).offset(x: width * 0.08 + CGFloat(slot) * 4, y: base - lift)
            // Lifting does not change depth: later envelopes remain behind earlier ones.
            .zIndex(Double(90 - slot)).animation(motion, value: front).animation(motion, value: selectedID)
            .accessibilityLabel(letter.displayTitle + ", " + letter.author).accessibilityAddTraits(selectedID == letter.id ? .isSelected : [])
    }
    private func sweep(_ point: CGPoint) {
        guard !visible.isEmpty else { return }
        let slot = min(visible.count - 1, max(0, Int(((160 - point.y) / 15).rounded())))
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
