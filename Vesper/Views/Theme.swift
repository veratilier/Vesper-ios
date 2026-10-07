import SwiftUI
import PhotosUI
import ImageIO
import CryptoKit

enum VesperPalette: String, CaseIterable, Identifiable {
    case white, black, blue
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var background: String { self == .white ? "WhiteScene" : self == .black ? "BlackScene" : "Marble" }
    var emblem: String { self == .white ? "WhiteEmblem" : self == .black ? "BlackEmblem" : "OpeningScene" }
    var swatch: Color { self == .white ? .white : self == .black ? .black : Color(red: 0.55, green: 0.74, blue: 0.84) }
    var ink: Color { self == .black ? Color(white: 0.94) : self == .white ? Color(white: 0.09) : Color(red: 0.17, green: 0.23, blue: 0.27) }
    var muted: Color { self == .black ? Color(white: 0.73) : Color(red: 0.34, green: 0.42, blue: 0.46) }
    var accent: Color { self == .black ? Color(white: 0.82) : Color(red: 0.38, green: 0.55, blue: 0.64) }
    var surface: Color { self == .black ? Color(white: 0.12).opacity(0.85) : .white.opacity(0.72) }
}
enum NavigationStyle: String, CaseIterable { case native, vesper }
enum VesperTheme {
    static var palette: VesperPalette { VesperPalette(rawValue: UserDefaults.standard.string(forKey: "vesperPalette") ?? "blue") ?? .blue }
    static var ink: Color { palette.ink }
    static var muted: Color { palette.muted }
    static var accent: Color { palette.accent }
    static var surface: Color { palette.surface }
    static func title(_ size: CGFloat = 32) -> Font { .custom("Ballet-Regular", size: size, relativeTo: .title) }
}
enum GlassAppearance {
    static func opacity(transparency: Double) -> Double {
        1 - (transparency.isFinite ? min(1, max(0, transparency)) : 0)
    }
}

private struct VesperGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @AppStorage("glassTransparency") private var transparency = 0.0
    @AppStorage("vesperPalette") private var palette = "blue"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        // Fade only the surface. Text, icons, and the control's hit area stay intact.
        content.contentShape(shape).background {
            if reduceTransparency {
                shape.fill(palette == "black" ? Color(white: 0.12) : .white)
            } else {
                surface.opacity(GlassAppearance.opacity(transparency: transparency))
            }
        }
    }
    @ViewBuilder private var surface: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            shape.fill(.clear).glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else { fallback }
        #else
        fallback
        #endif
    }
    private var fallback: some View {
        shape.fill(.ultraThinMaterial).overlay(shape.stroke(.white.opacity(0.55), lineWidth: 1))
    }
}
private struct VesperMaterialModifier<S: Shape>: ViewModifier {
    let material: Material
    let shape: S
    @AppStorage("glassTransparency") private var transparency = 0.0
    @AppStorage("vesperPalette") private var palette = "blue"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.contentShape(shape).background {
            if reduceTransparency { shape.fill(palette == "black" ? Color(white: 0.12) : .white) }
            else { shape.fill(material).opacity(GlassAppearance.opacity(transparency: transparency)) }
        }
    }
}
extension View {
    func vesperGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(VesperGlassModifier(shape: shape, interactive: interactive))
    }
    func vesperMaterial<S: Shape>(_ material: Material, in shape: S) -> some View {
        modifier(VesperMaterialModifier(material: material, shape: shape))
    }
    func vesperMaterial(_ material: Material) -> some View {
        vesperMaterial(material, in: Rectangle())
    }
}
struct NavigationStyleToggle: View {
    @AppStorage("navigationStyle") private var navigationStyle = "vesper"
    var body: some View {
        #if targetEnvironment(macCatalyst)
        MacAppearanceButton()
        #else
        Button { navigationStyle = navigationStyle == "native" ? "vesper" : "native" } label: {
            Image(systemName: navigationStyle == "native" ? "sidebar.left" : "rectangle.bottomthird.inset.filled")
        }.accessibilityLabel(navigationStyle == "native" ? "Switch to Vesper" : "Switch to Apple Native")
            .accessibilityValue(navigationStyle == "native" ? "Apple Native" : "Vesper")
        #endif
    }
}

@MainActor final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Appearance", isDirectory: true))
    struct SavedPhoto: Identifiable {
        let id: String
        let thumbnail: UIImage
    }
    @Published private(set) var image: UIImage?
    @Published private(set) var history: [SavedPhoto] = []
    @Published private(set) var selectedID: String?
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("background.jpg") }
    init(directory: URL) {
        self.directory = directory
        image = UIImage(contentsOfFile: file.path)
        // Preserve the wallpaper imported before background history was introduced.
        if let data = try? Data(contentsOf: file), image != nil {
            selectedID = Self.photoID(data)
            try? archive(data)
        }
        reloadHistory()
    }
    private var historyDirectory: URL { directory.appendingPathComponent("History", isDirectory: true) }
    private static func photoID(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func archive(_ data: Data) throws {
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let destination = historyDirectory.appendingPathComponent(Self.photoID(data) + ".jpg")
        if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
    }
    private func reloadHistory() {
        let files = (try? FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        history = files.filter { $0.pathExtension == "jpg" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.compactMap { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 200,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return SavedPhoto(id: url.deletingPathExtension().lastPathComponent, thumbnail: UIImage(cgImage: thumbnail))
        }
    }
    func select(_ id: String) throws {
        guard history.contains(where: { $0.id == id }) else { throw ServiceError(message: "This background is unavailable.") }
        let data = try Data(contentsOf: historyDirectory.appendingPathComponent(id + ".jpg"))
        guard let decoded = UIImage(data: data) else { throw ServiceError(message: "Could not read this background.") }
        try data.write(to: file, options: .atomic)
        image = decoded; selectedID = id
    }
    func importPhoto(_ data: Data) async throws {
        let jpeg = try await Task.detached(priority: .userInitiated) { try Self.preparePhoto(data) }.value
        try Task.checkCancellation()
        guard let decoded = UIImage(data: jpeg) else { throw ServiceError(message: "Could not read this photo.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try archive(jpeg)
        try jpeg.write(to: file, options: .atomic)
        image = decoded; selectedID = Self.photoID(jpeg)
        reloadHistory()
    }
    func reset() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        image = nil; selectedID = nil
    }
    // Downsample before decoding full-resolution camera images; apply EXIF rotation.
    nonisolated static func preparePhoto(_ data: Data) throws -> Data {
        guard data.count <= 50 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9) else {
            throw ServiceError(message: "Choose a readable photo under 50 MB.")
        }
        return jpeg
    }
}

struct WallpaperArtwork: View {
    let palette: String
    var opening = false
    @ObservedObject private var wallpaper = WallpaperStore.shared
    var body: some View {
        Group {
            if let image = wallpaper.image { Image(uiImage: image).resizable() }
            else { Image(opening && palette == "blue" ? "OpeningScene" : (VesperPalette(rawValue: palette) ?? .blue).background).resizable() }
        }.scaledToFill()
    }
}
struct Background: View {
    @AppStorage("vesperPalette") private var palette = "blue"
    @AppStorage("wallpaperShade") private var shade = 0.16
    var body: some View {
        GeometryReader { g in
            WallpaperArtwork(palette: palette)
                .frame(width: g.size.width, height: g.size.height).clipped()
                .overlay(palette == "black" ? Color.black.opacity(shade) : Color.white.opacity(shade))
        }.ignoresSafeArea()
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("vesperPalette") private var palette = "blue"
    @AppStorage("wallpaperShade") private var shade = 0.16
    @AppStorage("glassTransparency") private var glassTransparency = 0.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var wallpaper = WallpaperStore.shared
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var changingIcon = false
    @State private var selectedIcon = ThemeIcons.currentValue
    @State private var copiedMacIcon = ""
    @State private var issue: String?
    @State private var showingIssue = false
    @Environment(\.scenePhase) private var phase

    private func backgroundThumbnail(_ image: Image, selected: Bool) -> some View {
        image.resizable().scaledToFill().frame(width: 76, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? VesperTheme.accent : .white.opacity(0.3), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .bottomTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, VesperTheme.accent).padding(5) }
            }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Background") {
                    GeometryReader { area in
                        WallpaperArtwork(palette: palette)
                            .frame(width: area.size.width, height: 180).clipped()
                            .overlay(palette == "black" ? Color.black.opacity(shade) : Color.white.opacity(shade))
                            .overlay {
                                VStack(spacing: 8) {
                                    Text("Vesper").font(VesperTheme.title(36))
                                    Text("Somewhere we belong.").font(.subheadline)
                                }.foregroundStyle((VesperPalette(rawValue: palette) ?? .blue).ink)
                            }
                    }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 18))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(wallpaper.history) { saved in
                                Button { perform { try wallpaper.select(saved.id) } } label: {
                                    backgroundThumbnail(Image(uiImage: saved.thumbnail), selected: wallpaper.selectedID == saved.id)
                                }.accessibilityLabel("Saved background").accessibilityAddTraits(wallpaper.selectedID == saved.id ? .isSelected : [])
                            }
                            ForEach(VesperPalette.allCases) { item in
                                Button { perform { try wallpaper.reset(); palette = item.rawValue } } label: {
                                    backgroundThumbnail(Image(item.background), selected: wallpaper.image == nil && palette == item.rawValue)
                                }.accessibilityLabel(item.name + " background")
                            }
                        }.padding(3)
                    }.accessibilityIdentifier("background-history").disabled(importing)
                    PhotosPicker(selection: $photo, matching: .images) {
                        HStack { Label("Choose photo", systemImage: "photo"); Spacer(); if importing { ProgressView() } }
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.disabled(importing)
                    HStack { Text(palette == "black" ? "Darken background" : "Lighten background"); Spacer(); Text("\(Int(shade * 100))%") }
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                    Slider(value: $shade, in: 0...0.7).accessibilityLabel("Background readability")
                }
                section("Glass") {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Glass preview").font(.headline)
                            Text("Cards and buttons").font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        Spacer()
                    }.padding(.vertical, 8)
                    HStack {
                        Text("Glass transparency")
                        Spacer()
                        Text("\(Int(((1 - GlassAppearance.opacity(transparency: glassTransparency)) * 100).rounded()))%")
                            .monospacedDigit()
                    }.font(.subheadline)
                    Slider(value: $glassTransparency, in: 0...1, step: 0.01)
                        .disabled(reduceTransparency).accessibilityLabel("Glass transparency")
                    HStack {
                        Text("Less transparent")
                        Spacer()
                        Text("More transparent")
                    }.font(.caption).foregroundStyle(VesperTheme.muted)
                    Text(reduceTransparency ? "Reduce Transparency is enabled in system settings." : "Adjusts Vesper’s glass surfaces. System bars keep their system appearance.")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                    Button("Reset glass transparency") { glassTransparency = 0 }
                        .font(.subheadline).frame(minHeight: 44)
                }
                section("Colors") {
                    HStack(spacing: 12) {
                        ForEach(VesperPalette.allCases) { item in
                            Button { palette = item.rawValue } label: {
                                VStack(spacing: 8) {
                                    Circle().fill(item.swatch).frame(width: 36, height: 36)
                                        .overlay(Circle().stroke(.gray.opacity(0.6)))
                                        .overlay { if palette == item.rawValue { Image(systemName: "checkmark").foregroundStyle(item == .black ? .white : .black) } }
                                    Text(item.name).font(.caption)
                                }.frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
                            }.accessibilityAddTraits(palette == item.rawValue ? .isSelected : [])
                        }
                    }
                }
                section("App icon") {
                    #if targetEnvironment(macCatalyst)
                    Text("This Mac build uses the White icon.").font(.subheadline)
                    HStack(spacing: 12) {
                        ForEach([VesperPalette.white, .black]) { item in
                            Button {
                                if let image = ThemeIcons.preview(item.rawValue) {
                                    UIPasteboard.general.image = image; copiedMacIcon = item.name
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    iconPreview(item).frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 13))
                                    Text("Copy " + item.name).font(.caption)
                                }.frame(maxWidth: .infinity)
                            }.accessibilityLabel("Copy " + item.name + " icon for Finder")
                        }
                    }
                    Text(copiedMacIcon.isEmpty
                         ? "To customize the Mac app icon, copy an icon here. In Finder, select Vesper Mac → Get Info, select the small icon at the top left, then paste."
                         : copiedMacIcon + " icon copied. In Finder, select Vesper Mac → Get Info, select the small icon at the top left, then press ⌘V.")
                        .font(.caption).foregroundStyle(VesperTheme.muted).textSelection(.enabled)
                    #else
                    HStack(spacing: 12) {
                        ForEach(VesperPalette.allCases) { item in
                            Button { changeIcon(item.rawValue) } label: {
                                VStack(spacing: 8) {
                                    iconPreview(item).frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 13))
                                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedIcon == item.rawValue ? VesperTheme.ink : .clear, lineWidth: 2).padding(-4))
                                    HStack(spacing: 3) {
                                        Text(item.name)
                                        if selectedIcon == item.rawValue { Image(systemName: "checkmark") }
                                    }.font(.caption)
                                }.frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
                            }.disabled(changingIcon).accessibilityLabel(item.name + " App icon")
                                .accessibilityAddTraits(selectedIcon == item.rawValue ? .isSelected : [])
                        }
                    }
                    if changingIcon { ProgressView("Changing icon…").font(.caption) }
                    #endif
                }
            }.padding(20).frame(maxWidth: 580).frame(maxWidth: .infinity)
        }.background { Background() }.navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
            .transparentNavigationTop().buttonStyle(.plain)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                if issue != nil { Button { showingIssue = true } label: { Image(systemName: "exclamationmark.circle") }.accessibilityLabel("Appearance error details") }
            } }
            .sheet(isPresented: $showingIssue) {
                NavigationStack {
                    ScrollView { Text(issue ?? "").frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                        .background { Background() }.navigationTitle("Appearance")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingIssue = false } } }
                }.presentationDetents([.medium]).presentationDragIndicator(.visible)
            }
            .task(id: photo) {
                guard let photo else { return }
                importing = true
                defer { importing = false }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else { throw ServiceError(message: "Could not read this photo.") }
                    try await wallpaper.importPhoto(data)
                    issue = nil
                } catch { if !Task.isCancelled { issue = error.localizedDescription } }
                self.photo = nil
            }
            .onChange(of: phase) { _, value in if value == .active { selectedIcon = ThemeIcons.currentValue } }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12, content: content).padding(18)
                .vesperGlass(in: RoundedRectangle(cornerRadius: 24))
        }
    }
    @ViewBuilder private func iconPreview(_ item: VesperPalette) -> some View {
        if let image = ThemeIcons.preview(item.rawValue) { Image(uiImage: image).resizable().scaledToFit() }
        else { Image(item.emblem).resizable().scaledToFill() }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); issue = nil } catch { issue = error.localizedDescription }
    }
    private func changeIcon(_ value: String) {
        changingIcon = true
        Task {
            defer { changingIcon = false }
            do { try await ThemeIcons.apply(value); selectedIcon = ThemeIcons.currentValue; issue = nil }
            catch { issue = error.localizedDescription }
        }
    }
}
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .vesperMaterial(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
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
    static var currentValue: String {
        switch UIApplication.shared.alternateIconName {
        case "AppIconWhite": "white"
        case "AppIconBlack": "black"
        default: "blue"
        }
    }
    static func name(for value: String) -> String? {
        value == "white" ? "AppIconWhite" : value == "black" ? "AppIconBlack" : nil
    }
    static func preview(_ value: String) -> UIImage? {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let details: [String: Any]?
        if let name = name(for: value) { details = (icons?["CFBundleAlternateIcons"] as? [String: [String: Any]])?[name] }
        else { details = icons?["CFBundlePrimaryIcon"] as? [String: Any] }
        #if !targetEnvironment(macCatalyst)
        if let file = (details?["CFBundleIconFiles"] as? [String])?.last, let image = UIImage(named: file) { return image }
        #endif
        // Asset-catalog alternate icons have no public UIImage file name. Match
        // the centered crop used by prepare_icons.sh for their source artwork.
        guard value == "white" || value == "black",
              let source = UIImage(named: value == "white" ? "WhiteEmblem" : "BlackEmblem")?.cgImage else { return nil }
        let side = min(value == "white" ? 760 : 980, min(source.width, source.height))
        let rect = CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        return source.cropping(to: rect).map { UIImage(cgImage: $0) }
    }
    static func apply(_ value: String) async throws {
        guard UIApplication.shared.supportsAlternateIcons else { throw ServiceError(message: "App icon changes are not available on this device.") }
        let icon = name(for: value)
        guard UIApplication.shared.alternateIconName != icon else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UIApplication.shared.setAlternateIconName(icon) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
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
