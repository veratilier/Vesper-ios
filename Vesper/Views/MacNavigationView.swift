#if targetEnvironment(macCatalyst)
import SwiftUI

/// Desktop navigation is independent of the iPhone's floating bottom bar.
struct MacNavigationView<Detail: View>: View {
    @Binding var selection: Destination
    let openMusic: () -> Void
    @ViewBuilder var detail: (Destination) -> Detail
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var inbox = ChatInbox.shared
    private let primary: [Destination] = [.home, .chat, .letters]
    private var collection: [Destination] { VesperGridOrder.defaults.filter { $0 != .alarms } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Vesper").font(.custom("Ballet", size: 48)).padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(primary) { row($0) }
                        Text("COLLECTION").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                            .foregroundStyle(VesperTheme.muted).padding(.top, 22).padding(.bottom, 8).padding(.leading, 12)
                        ForEach(collection) { row($0) }
                    }.padding(.horizontal, 10)
                }
                if !store.connected {
                    Button { selection = .settings } label: {
                        Label("Connect Vesper", systemImage: "link").font(.caption)
                    }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 12)
                }
                Divider().padding(.vertical, 12)
                row(.settings).padding(.horizontal, 10).padding(.bottom, 12)
                if !store.token.isEmpty {
                    MiniMusicPlayer(openMusic: openMusic).padding(.horizontal, 8).padding(.bottom, 12)
                }
            }.frame(width: 190).frame(maxHeight: .infinity)
                .vesperMaterial(.regularMaterial)
            Divider()
            detail(selection).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { Background() }
        .background(MacWindowConfiguration())
        .task { if store.token.isEmpty { selection = .settings } }
    }
    private func row(_ page: Destination) -> some View {
        Button { selection = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon).frame(width: 22)
                Text(page.title).font(.system(size: 14, weight: selection == page ? .semibold : .regular))
                Spacer(minLength: 0)
                if page == .chat && inbox.hasUpdates { Circle().fill(.red).frame(width: 6, height: 6) }
            }.padding(.horizontal, 12).frame(height: 38)
                .background(selection == page ? VesperTheme.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("mac-nav-" + page.rawValue)
    }
}
private struct MacWindowConfiguration: UIViewRepresentable {
    final class WindowProbe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 980, height: 650)
        }
    }
    func makeUIView(context: Context) -> WindowProbe { WindowProbe() }
    func updateUIView(_ uiView: WindowProbe, context: Context) {}
}

struct MacAppearanceButton: View {
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "paintpalette") }
            .accessibilityLabel("Appearance")
            .sheet(isPresented: $showing) {
                NavigationStack {
                    AppearanceSettingsView().toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } }
                    }
                }.frame(minWidth: 480, minHeight: 600)
            }
    }
}
#endif
