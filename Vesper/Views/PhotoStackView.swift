import SwiftUI
import WebKit
import UIKit

/// The actual Wren036/PhotoStack JS/CSS runs locally, with native photo viewing.
/// Required Notice: PhotoStack by Wren036 (https://github.com/Wren036/PhotoStack).
struct ChatPhotoStack: View {
    let photos: [JSONValue]
    @State private var front = 0
    @State private var showingPhoto = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if photos.count > 1 {
                Label("\(photos.count) Photos", systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(VesperTheme.accent)
                PhotoStackWebView(urls: photos.map { $0["url"].string }, reducedMotion: reduceMotion,
                    onChange: { front = $0 }, onTap: { front = $0; showingPhoto = true })
                    .frame(maxWidth: 320).frame(height: 226)
                    .accessibilityIdentifier("chat-photo-stack")
            } else if let photo = photos.first {
                AsyncImage(url: URL(string: photo["url"].string)) { image in
                    image.resizable().scaledToFit().frame(maxWidth: 276, maxHeight: 320)
                } placeholder: {
                    ZStack { VesperTheme.accent.opacity(0.16); Image(systemName: "photo").foregroundStyle(VesperTheme.muted) }
                        .frame(width: 240, height: 240)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onTapGesture { front = 0; showingPhoto = true }
                .accessibilityLabel("Photo")
                .accessibilityAddTraits(.isButton)
            }
        }
        .onChange(of: photos) { _, _ in front = 0; showingPhoto = false }
        .sheet(isPresented: $showingPhoto) {
            NavigationStack {
                TabView(selection: $front) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                        AsyncImage(url: URL(string: photo["url"].string)) { image in image.resizable().scaledToFit() }
                            placeholder: { ProgressView().tint(.white) }
                            .tag(index).accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                    }
                }.tabViewStyle(.page(indexDisplayMode: .automatic))
                    .background(.black).ignoresSafeArea(edges: .bottom)
                    .navigationTitle("\(front + 1) / \(photos.count)").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showingPhoto = false } }
                    .preferredColorScheme(.dark)
            }
        }
    }
}

struct PhotoStackWebView: UIViewRepresentable {
    let urls: [String]
    var reducedMotion = false
    let onChange: (Int) -> Void
    let onTap: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onTap: onTap) }
    func makeUIView(context: Context) -> PhotoStackSurface {
        let view = PhotoStackSurface()
        context.coordinator.webView = view
        view.navigationDelegate = context.coordinator
        view.configuration.userContentController.add(context.coordinator, name: "photoStack")
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Previous photo", target: context.coordinator, selector: #selector(Coordinator.previousPhoto)),
            UIAccessibilityCustomAction(name: "Next photo", target: context.coordinator, selector: #selector(Coordinator.nextPhoto)),
            UIAccessibilityCustomAction(name: "Open photo", target: context.coordinator, selector: #selector(Coordinator.openPhoto))]
        view.configure(urls: urls, reducedMotion: reducedMotion)
        return view
    }
    func updateUIView(_ view: PhotoStackSurface, context: Context) {
        context.coordinator.onChange = onChange; context.coordinator.onTap = onTap
        view.configure(urls: urls, reducedMotion: reducedMotion)
    }
    static func dismantleUIView(_ view: PhotoStackSurface, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "photoStack")
        view.navigationDelegate = nil; view.stopLoading()
        view.evaluateJavaScript("if(window.stack)window.stack.destroy();")
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: PhotoStackSurface?
        var onChange: (Int) -> Void
        var onTap: (Int) -> Void
        private var front = 0
        init(onChange: @escaping (Int) -> Void, onTap: @escaping (Int) -> Void) { self.onChange = onChange; self.onTap = onTap }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { (webView as? PhotoStackSurface)?.mount() }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let index = body["index"] as? Int, let webView, webView.photoURLs.indices.contains(index) else { return }
            front = index
            webView.accessibilityLabel = "Photo \(index + 1) of \(webView.photoURLs.count)"
            if body["action"] as? String == "tap" { onTap(index) }
            else if ["change", "ready"].contains(body["action"] as? String ?? "") { onChange(index) }
        }
        @objc func nextPhoto() -> Bool { webView?.evaluateJavaScript("window.stack?.next()"); return true }
        @objc func previousPhoto() -> Bool { webView?.evaluateJavaScript("window.stack?.prev()"); return true }
        @objc func openPhoto() -> Bool { onTap(front); return true }
    }
}

@MainActor final class PhotoStackSurface: WKWebView {
    private(set) var photoURLs: [String] = []
    private var reducedMotion = false
    private var mountedURLs: [String]?
    private var mountedReducedMotion = false
    private var ready = false
    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
        isOpaque = false; backgroundColor = .clear; scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = false; scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        isAccessibilityElement = true
        accessibilityHint = "Swipe left or right to turn photos. Use the actions to turn or open a photo."
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func configure(urls: [String], reducedMotion: Bool) {
        photoURLs = urls.map(Self.safeImageURL)
        self.reducedMotion = reducedMotion
        if ready { mount() }
        else if url == nil, !isLoading, let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "PhotoStack") {
            loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }
    func mount() {
        ready = true
        guard mountedURLs != photoURLs else {
            if mountedReducedMotion != reducedMotion {
                mountedReducedMotion = reducedMotion
                evaluateJavaScript("window.setReducedMotion(\(reducedMotion ? "true" : "false"));")
            }
            return
        }
        mountedURLs = photoURLs; mountedReducedMotion = reducedMotion
        guard let data = try? JSONEncoder().encode(photoURLs), let json = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("window.setPhotos(\(json), \(reducedMotion ? "true" : "false"));")
    }
    static func safeImageURL(_ value: String) -> String {
        if let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return value }
        if value.hasPrefix("data:image/") { return value }
        return "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='190' height='254'%3E%3Crect width='190' height='254' fill='%23dce5e8'/%3E%3C/svg%3E"
    }
}
