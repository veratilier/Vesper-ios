import XCTest
import ZIPFoundation
@testable import Vesper

final class EPUBImporterTests: XCTestCase {
    func testXHTMLSourceWhitespaceDoesNotCreateParagraphs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try add("META-INF/container.xml", #"<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>"#, to: archive)
        try add("book.opf", #"<package><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>"#, to: archive)
        try add("one.xhtml", """
        <html><body>
          <p>第一行
             接着 <em>强调</em> 的文字。</p>
          <p>第二段<br/>段内换行。</p>
        </body></html>
        """, to: archive)
        XCTAssertEqual(try EPUBImporter.load(url).text, "第一行 接着 强调 的文字。\n第二段\n段内换行。")
    }

    func testEPUBUsesSpineOrderAndImportsTitleAndCover() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try add("META-INF/container.xml", #"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>"#, to: archive)
        try add("OEBPS/book.opf", #"<?xml version="1.0"?><package><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">测试 EPUB</dc:title><meta name="cover" content="cover"/></metadata><manifest><item id="second" href="two.xhtml" media-type="application/xhtml+xml"/><item id="first" href="one.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="cover.jpg" media-type="image/jpeg"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>"#, to: archive)
        try add("OEBPS/one.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignore me</title></head><body><h1>第一章</h1><p>先读这一段。</p><script>not book text</script></body></html>"#, to: archive)
        try add("OEBPS/two.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>再读这一段。</p></body></html>"#, to: archive)
        try add("OEBPS/cover.jpg", "cover", to: archive)

        let book = try EPUBImporter.load(url)
        XCTAssertEqual(book.title, "测试 EPUB")
        XCTAssertLessThan(try XCTUnwrap(book.text.range(of: "先读")).lowerBound, try XCTUnwrap(book.text.range(of: "再读")).lowerBound)
        XCTAssertTrue(book.text.contains("# 第一章"))
        XCTAssertFalse(book.text.contains("not book text"))
        XCTAssertEqual(book.cover, Data("cover".utf8))
    }

    private func add(_ path: String, _ text: String, to archive: Archive) throws {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        })
    }
}
