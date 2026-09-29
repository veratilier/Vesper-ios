import SwiftUI

/// Inline Markdown preserves message line breaks and exposes links to the system browser.
struct ChatMarkdownText: View {
    let content: String

    var body: some View {
        Text(Self.render(content))
            .tint(VesperTheme.accent)
            .textSelection(.enabled)
    }

    private static func render(_ content: String) -> AttributedString {
        let linked = linkBareURLs(in: content)
        return (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(content)
    }

    private static func linkBareURLs(in content: String) -> String {
        guard let detector = try? NSRegularExpression(pattern: #"(?<!\]\()https?://[^\s<>)\]]+"#) else { return content }
        var linked = content
        for match in detector.matches(in: content, range: NSRange(content.startIndex..., in: content)).reversed() {
            guard let range = Range(match.range, in: linked) else { continue }
            let raw = String(linked[range])
            let url = String(raw.dropLast(raw.reversed().prefix(while: { ".,;:!?".contains($0) }).count))
            guard !url.isEmpty else { continue }
            let trailing = String(raw.dropFirst(url.count))
            linked.replaceSubrange(range, with: "[\(url)](\(url))\(trailing)")
        }
        return linked
    }
}
