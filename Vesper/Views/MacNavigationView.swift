import SwiftUI

/// Large devices keep navigation visible independently of the phone tab style.
enum VesperLayout {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
    static var usesSidebar: Bool { isMac || UIDevice.current.userInterfaceIdiom == .pad }
}

/// Navigation adapts to the available window width on Mac and iPad.
struct MacNavigationView<Detail: View>: View {
    @Binding var selection: Destination
    let openMusic: () -> Void
    @ViewBuilder var detail: (Destination) -> Detail
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var inbox = ChatInbox.shared
    @State private var showingSidebar = false
    private let primary: [Destination] = [.home, .chat, .studio]
    private var collection: [Destination] { VesperGridOrder.defaults.filter { !VesperLayout.isMac || $0 != .alarms } }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if compact { compactSidebar }
                    else { fullSidebar }
                    Divider()
                    detail(selection).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if compact && showingSidebar {
                    Color.black.opacity(0.2).ignoresSafeArea()
                        .onTapGesture { withAnimation { showingSidebar = false } }
                        .accessibilityLabel("Close navigation").accessibilityAddTraits(.isButton)
                    fullSidebar.transition(.move(edge: .leading))
                        .shadow(color: .black.opacity(0.16), radius: 16, x: 5)
                }
            }
            .onChange(of: compact) { _, isCompact in
                if !isCompact { showingSidebar = false }
            }
        }
        .background { Background() }
        .background {
            #if targetEnvironment(macCatalyst)
            MacWindowConfiguration()
            #endif
        }
        .task { if store.token.isEmpty { selection = .settings } }
    }
    @ViewBuilder private var fullSidebar: some View {
        let sidebar = VStack(alignment: .leading, spacing: 0) {
            Text("Vesper").font(.custom("Ballet", size: 48))
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
                .overlay(alignment: .topTrailing) {
                    if showingSidebar {
                        Button { withAnimation { showingSidebar = false } } label: {
                            Image(systemName: "sidebar.left").frame(width: 36, height: 44)
                        }.accessibilityLabel("Close navigation").padding(.top, 8)
                    }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(primary) { row($0) }
                    Text("COLLECTION").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(VesperTheme.muted).padding(.top, 22).padding(.bottom, 8).padding(.leading, 12)
                    ForEach(collection) { row($0) }
                }.padding(.horizontal, 10)
            }
            if !store.connected && !store.hasLocalData {
                Button { selection = .settings; showingSidebar = false } label: {
                    Label("Connect Vesper", systemImage: "link").font(.caption)
                }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 12)
            }
            Divider().padding(.vertical, 12)
            row(.settings).padding(.horizontal, 10).padding(.bottom, 12)
            MacSidebarPlayer(openMusic: openMusic)
                .padding(.horizontal, 10).padding(.bottom, 12)
        }.frame(width: 190).frame(maxHeight: .infinity)
        if showingSidebar {
            // Clear liquid glass reveals both the compact rail and the page beneath an overlay.
            sidebar.background(VesperTheme.palette == .black ? Color(white: 0.10) : Color(white: 0.97))
        } else {
            sidebar.vesperMaterial(.regularMaterial)
        }
    }
    private var compactSidebar: some View {
        VStack(spacing: 4) {
            Button { withAnimation { showingSidebar = true } } label: {
                Image(systemName: "sidebar.left").frame(width: 48, height: 48)
            }.accessibilityLabel("Open navigation")
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(primary + collection) { page in
                        Button { selection = page } label: {
                            Image(systemName: page.icon)
                                .font(.system(size: 18))
                                .frame(width: 48, height: 44)
                                .background(selection == page ? VesperTheme.ink.opacity(0.1) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }.accessibilityLabel(page.title)
                            .accessibilityIdentifier("mac-nav-" + page.rawValue)
                    }
                }
            }.scrollIndicators(.hidden)
            Button { selection = .settings } label: {
                Image(systemName: Destination.settings.icon).frame(width: 48, height: 48)
                    .background(selection == .settings ? VesperTheme.ink.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
            }.accessibilityLabel("Settings").accessibilityIdentifier("mac-nav-settings")
        }.buttonStyle(.plain).frame(width: 56).frame(maxHeight: .infinity)
            .vesperMaterial(.regularMaterial)
    }
    private func row(_ page: Destination) -> some View {
        Button { selection = page; showingSidebar = false } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon).frame(width: 22)
                Text(page.title).font(.system(size: 14, weight: selection == page ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: VesperLayout.isMac ? 38 : 44)
                .background(selection == page ? VesperTheme.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("mac-nav-" + page.rawValue)
    }
}
/// The phone dock's artwork, text and two 44-point buttons cannot fit a sidebar.
/// Keep metadata and playback controls on separate rows with bounded artwork.
private struct MacSidebarPlayer: View {
    @EnvironmentObject private var player: MusicPlayer
    let openMusic: () -> Void
    private var title: String { player.track["title"].string }
    var body: some View {
        VStack(spacing: 4) {
            Button(action: openMusic) {
                HStack(spacing: 8) {
                    Artwork(url: player.track["cover"].string)
                        .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.isEmpty ? "Choose a song" : title)
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if !player.track["artist"].string.isEmpty {
                            Text(player.track["artist"].string).font(.system(size: 10))
                                .foregroundStyle(VesperTheme.muted).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.accessibilityLabel("Open Music, " + (title.isEmpty ? "Choose a song" : title))
            HStack(spacing: 0) {
                control("backward.fill", label: "Previous song") { player.next(-1) }
                control(player.playing ? "pause.fill" : "play.fill", label: player.playing ? "Pause" : "Play") { player.toggle() }
                control("forward.fill", label: "Next song") { player.next(1) }
            }.disabled(player.tracks.isEmpty)
        }.buttonStyle(.plain).padding(10)
            .frame(maxWidth: .infinity)
            .vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("mac-sidebar-player")
    }
    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: VesperLayout.isMac ? 28 : 44).contentShape(Rectangle())
        }.accessibilityLabel(label)
    }
}

#if targetEnvironment(macCatalyst)
private struct MacWindowConfiguration: UIViewRepresentable {
    final class WindowProbe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 700, height: 500)
            window?.windowScene?.sizeRestrictions?.maximumSize = CGSize(width: 4096, height: 4096)
        }
    }
    func makeUIView(context: Context) -> WindowProbe { WindowProbe() }
    func updateUIView(_ uiView: WindowProbe, context: Context) {}
}

#endif

struct MacAppearanceButton: View {
    var title: String? = nil
    @State private var showing = false
    @AppStorage("vesperPalette") private var palette = "blue"
    var body: some View {
        Button { showing = true } label: {
            if let title {
                Label(title, systemImage: "paintpalette")
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .contentShape(Rectangle())
            }
            else { Image(systemName: "paintpalette") }
        }
            .buttonStyle(.plain)
            .accessibilityLabel("Appearance")
            .sheet(isPresented: $showing) {
                NavigationStack {
                    AppearanceSettingsView().toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } }
                    }
                }.frame(minWidth: 480, minHeight: 600)
                    .preferredColorScheme(palette == "black" ? .dark : .light)
                    .foregroundStyle((VesperPalette(rawValue: palette) ?? .blue).ink)
                    .tint((VesperPalette(rawValue: palette) ?? .blue).ink)
            }
    }
}
