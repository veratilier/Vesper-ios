import SwiftUI

/// Inline Markdown preserves line breaks; web links open without leaving the chat.
struct ChatMarkdownText: View {
    let content: String
    var selectable = true

    var body: some View {
        Text(Self.render(content))
            .tint(VesperTheme.accent)
            .modifier(ChatTextSelection(enabled: selectable))
            .modifier(ChatInAppLinks())
    }

    private final class Rendered: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    private static let cache: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>()
        cache.countLimit = 150
        cache.totalCostLimit = 2_000_000
        return cache
    }()

    static func render(_ content: String) -> AttributedString {
        if let rendered = cache.object(forKey: content as NSString) { return rendered.text }
        var text = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(content)
        // Markdown's automatic link detection can include Chinese sentence
        // punctuation even though NSDataDetector excludes it. Normalize only
        // URL labels matching their destination; named Markdown links stay exact.
        for run in Array(text.runs) {
            let label = String(text[run.range].characters)
            guard let link = run.link, ChatWebURL.accepts(link), URL(string: label) == link else { continue }
            let trimmed = String(label.dropLast(label.reversed().prefix(while: { "。！？；，、】”’".contains($0) }).count))
            guard trimmed != label, let url = URL(string: trimmed) else { continue }
            let end = text.characters.index(run.range.lowerBound, offsetBy: trimmed.count)
            text[run.range].link = nil
            text[run.range.lowerBound..<end].link = url
        }
        let plain = String(text.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let detected = match.url, ChatWebURL.accepts(detected),
                      let range = Range(match.range, in: plain) else { continue }
                let raw = String(plain[range])
                let trimmed = String(raw.dropLast(raw.reversed().prefix(while: { "。！？；，、】”’".contains($0) }).count))
                let url = URL(string: trimmed).flatMap { ChatWebURL.accepts($0) ? $0 : nil } ?? detected
                let last = plain.index(range.lowerBound, offsetBy: trimmed.count)
                guard let start = AttributedString.Index(range.lowerBound, within: text),
                      let end = AttributedString.Index(last, within: text),
                      let detectedEnd = AttributedString.Index(range.upperBound, within: text) else { continue }
                let runs = text[start..<detectedEnd].runs
                guard !runs.contains(where: { ($0.link != nil && $0.link != detected) || $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
                text[start..<detectedEnd].link = nil
                text[start..<end].link = url
            }
        }
        cache.setObject(Rendered(text), forKey: content as NSString, cost: content.utf8.count)
        return text
    }

}

private struct ChatTextSelection: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
