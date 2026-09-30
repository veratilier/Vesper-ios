import SwiftUI

enum VesperPalette: String, CaseIterable, Identifiable {
    case white, black, blue
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var background: String { self == .white ? "WhiteScene" : self == .black ? "BlackScene" : "Marble" }
    var emblem: String { self == .white ? "WhiteEmblem" : self == .black ? "BlackEmblem" : "OpeningScene" }
    var swatch: Color { self == .white ? .white : self == .black ? .black : Color(red: 0.55, green: 0.74, blue: 0.84) }
}
enum NavigationStyle: String, CaseIterable { case native, vesper }
enum VesperTheme {
    static var palette: VesperPalette { VesperPalette(rawValue: UserDefaults.standard.string(forKey: "vesperPalette") ?? "blue") ?? .blue }
    static var ink: Color { palette == .black ? Color(white: 0.94) : palette == .white ? Color(white: 0.09) : Color(red: 0.17, green: 0.23, blue: 0.27) }
    static var muted: Color { palette == .black ? Color(white: 0.73) : Color(red: 0.34, green: 0.42, blue: 0.46) }
    static var accent: Color { palette == .black ? Color(white: 0.82) : Color(red: 0.38, green: 0.55, blue: 0.64) }
    static var surface: Color { palette == .black ? Color(white: 0.12).opacity(0.85) : .white.opacity(0.72) }
    static func title(_ size: CGFloat = 32) -> Font { .custom("Ballet-Regular", size: size, relativeTo: .title) }
}
struct AppearancePicker: View {
    @AppStorage("navigationStyle") private var navigationStyle = "vesper"
    @AppStorage("vesperPalette") private var palette = "blue"
    @State private var showing = false
    @AppStorage("iconChangeError") private var iconError = ""
    var body: some View {
        Button { showing = true } label: { Image(systemName: "paintpalette") }
            .accessibilityLabel("Appearance")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Appearance").font(.headline)
                    Picker("Navigation", selection: $navigationStyle) {
                        Text("Apple Native").tag("native")
                        Text("Vesper").tag("vesper")
                    }.pickerStyle(.segmented)
                    HStack(spacing: 24) {
                        ForEach(VesperPalette.allCases) { item in
                            Button { palette = item.rawValue } label: {
                                VStack(spacing: 7) {
                                    Circle().fill(item.swatch).frame(width: 34, height: 34)
                                        .overlay(Circle().stroke(.gray, lineWidth: 1))
                                        .overlay { if palette == item.rawValue { Image(systemName: "checkmark").foregroundStyle(item == .black ? .white : .black) } }
                                    Text(item.name).font(.caption)
                                }
                            }.buttonStyle(.plain).accessibilityAddTraits(palette == item.rawValue ? .isSelected : [])
                        }
                    }.frame(maxWidth: .infinity)
                    if !iconError.isEmpty { Text(iconError).font(.caption).foregroundStyle(.secondary) }
                }.padding(22).frame(width: 310).presentationCompactAdaptation(.popover)
            }
    }
}
struct Background: View {
    @AppStorage("vesperPalette") private var palette = "blue"
    var body: some View {
        GeometryReader { g in
            Image((VesperPalette(rawValue: palette) ?? .blue).background).resizable().scaledToFill()
                .frame(width: g.size.width, height: g.size.height).clipped()
                .overlay(palette == "black" ? Color.black.opacity(0.18) : Color.white.opacity(0.16))
        }.ignoresSafeArea()
    }
}
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.8), lineWidth: 1.5))
    }
}
struct Page<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(VesperTheme.title(38))
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(VesperTheme.muted) }
                }.padding(.vertical, 8)
                content
            }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
    }
}
struct EmptyCard: View {
    let title: String
    let message: String
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(VesperTheme.muted).font(.subheadline)
            }.padding(.vertical, 12)
        }
    }
}
struct FormField: View {
    let label: String
    @Binding var text: String
    var multiline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(VesperTheme.muted)
            if multiline {
                TextEditor(text: $text).frame(minHeight: 160).scrollContentBackground(.hidden)
            } else { TextField(label, text: $text) }
        }.padding(12).background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct EditorSheet<Content: View>: View {
    let title: String
    var busy = false
    let save: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack { Background(); ScrollView { VStack(spacing: 16) { content }.padding(20) } }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(busy) }
                }
        }.presentationDragIndicator(.visible)
    }
}

@MainActor enum ThemeIcons {
    static func apply(_ value: String) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let name: String? = value == "white" ? "AppIconWhite" : value == "black" ? "AppIconBlack" : nil
        guard UIApplication.shared.alternateIconName != name else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            DispatchQueue.main.async { UserDefaults.standard.set(error.map { "Theme applied; icon could not change: " + $0.localizedDescription } ?? "", forKey: "iconChangeError") }
        }
    }
}

extension View {
    /// Keep the wallpaper visible behind top navigation, including the iOS 26 scroll edge.
    @ViewBuilder func transparentNavigationTop() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.toolbarBackground(.hidden, for: .navigationBar)
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            self.toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        self.toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }
}
