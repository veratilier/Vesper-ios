import Foundation
import ZIPFoundation

struct EPUBBook {
    let title: String
    let text: String
    let cover: Data?
}

enum EPUBImporter {
    static func load(_ url: URL) throws -> EPUBBook {
        let archive = try Archive(url: url, accessMode: .read)
        let container = try read("META-INF/container.xml", from: archive, limit: 128_000)
        let location = EPUBContainerParser()
        guard location.parse(container), let packagePath = location.packagePath else {
            throw ServiceError(message: "This EPUB has no readable package file.")
        }
        let packageData = try read(packagePath, from: archive, limit: 1_000_000)
        let package = EPUBPackageParser()
        guard package.parse(packageData), !package.spine.isEmpty else {
            throw ServiceError(message: "This EPUB has no readable chapters.")
        }
        let directory = (packagePath as NSString).deletingLastPathComponent
        var chapters: [String] = []
        var characterCount = 0
        for id in package.spine {
            guard let item = package.manifest[id], item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" else { continue }
            let path = resolvedPath(item.href, relativeTo: directory)
            let chapterData = try read(path, from: archive, limit: 2_000_000)
            let chapter = EPUBChapterParser()
            guard chapter.parse(chapterData) else {
                throw ServiceError(message: "A chapter in this EPUB could not be read.")
            }
            let value = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            characterCount += value.count
            guard characterCount <= 500_000 else {
                throw ServiceError(message: "This book is over 500,000 characters. Split it into smaller volumes before importing.")
            }
            chapters.append(value)
        }
        guard !chapters.isEmpty else { throw ServiceError(message: "This EPUB has no readable text.") }
        let coverID = package.coverID ?? package.manifest.first(where: { $0.value.properties.contains("cover-image") })?.key
        let cover: Data?
        if let coverID, let item = package.manifest[coverID], item.mediaType.hasPrefix("image/") {
            cover = try? read(resolvedPath(item.href, relativeTo: directory), from: archive, limit: 5_000_000)
        } else { cover = nil }
        let title = package.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return EPUBBook(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                        text: chapters.joined(separator: "\n\n"), cover: cover)
    }

    private static func read(_ path: String, from archive: Archive, limit: Int) throws -> Data {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              let entry = archive[path], entry.type == .file, entry.uncompressedSize <= limit else {
            throw ServiceError(message: "The EPUB is missing a readable file or contains a file that is too large.")
        }
        var output = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            guard output.count + chunk.count <= limit else { throw ServiceError(message: "A file in this EPUB is too large.") }
            output.append(chunk)
        })
        return output
    }

    private static func resolvedPath(_ href: String, relativeTo directory: String) -> String {
        let clean = href.components(separatedBy: "#")[0].removingPercentEncoding ?? href
        let base = directory == "." ? "" : directory + "/"
        return (base + clean).split(separator: "/").reduce(into: [String]()) { parts, component in
            if component == "." { return }
            if component == ".." { if !parts.isEmpty { parts.removeLast() }; return }
            parts.append(String(component))
        }.joined(separator: "/")
    }
}

private class EPUBXMLParser: NSObject, XMLParserDelegate {
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        return parser.parse()
    }
    func localName(_ name: String) -> String { String(name.split(separator: ":").last ?? "").lowercased() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {}
    func parser(_ parser: XMLParser, foundCharacters string: String) {}
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {}
}

private final class EPUBContainerParser: EPUBXMLParser {
    var packagePath: String?
    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if localName(elementName) == "rootfile", packagePath == nil { packagePath = attributeDict["full-path"] }
    }
}

private final class EPUBPackageParser: EPUBXMLParser {
    struct Item { let href: String; let mediaType: String; let properties: Set<String> }
    var manifest: [String: Item] = [:]
    var spine: [String] = []
    var title = ""
    var coverID: String?
    private var inTitle = false
    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch localName(elementName) {
        case "title": inTitle = true
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = Item(href: href, mediaType: attributeDict["media-type"] ?? "",
                                    properties: Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init)))
            }
        case "itemref": if let id = attributeDict["idref"], attributeDict["linear"] != "no" { spine.append(id) }
        case "meta": if attributeDict["name"] == "cover" { coverID = attributeDict["content"] }
        default: break
        }
    }
    override func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { title += string } }
    override func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if localName(elementName) == "title" { inTitle = false }
    }
}

private final class EPUBChapterParser: EPUBXMLParser {
    private var result = ""
    private var inBody = false
    private var skippedDepth = 0
    var text: String {
        result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    }
    override func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = localName(elementName)
        if name == "body" { inBody = true }
        guard inBody else { return }
        if skippedDepth > 0 { skippedDepth += 1; return }
        if ["script", "style", "svg"].contains(name) { skippedDepth = 1; return }
        if ["p", "div", "section", "article", "blockquote", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
            if !result.hasSuffix("\n") { result += "\n" }
            if name.hasPrefix("h"), name.count == 2 { result += "# " }
        } else if name == "br" { result += "\n" }
    }
    override func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBody && skippedDepth == 0 {
            // XHTML source line breaks and indentation are HTML whitespace,
            // not paragraph breaks. Structural elements and <br> add those.
            if (result.isEmpty || result.hasSuffix("\n")),
               string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            result += string.replacingOccurrences(of: "[\\t\\r\\n]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\u{a0}", with: " ")
        }
    }
    override func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        if skippedDepth > 0 { skippedDepth -= 1; return }
        if name == "body" { inBody = false }
        if inBody && ["p", "div", "section", "article", "blockquote", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
            if !result.hasSuffix("\n") { result += "\n" }
        }
    }
}
