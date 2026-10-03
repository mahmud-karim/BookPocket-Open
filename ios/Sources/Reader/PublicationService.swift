import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumZIPFoundation

@MainActor final class PublicationService {
    private let http = DefaultHTTPClient()
    private lazy var assets = AssetRetriever(httpClient: http)
    private lazy var opener = PublicationOpener(parser: DefaultPublicationParser(httpClient: http, assetRetriever: assets, pdfFactory: DefaultPDFDocumentFactory()))
    func open(_ url: URL) async throws -> Publication {
        guard let file = FileURL(url: url) else { throw BookError.message("Invalid book location.") }
        let asset = try await assets.retrieve(url: file).get()
        let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
        guard !publication.isRestricted else { throw BookError.message("This book is protected by DRM. Import a DRM-free EPUB or text file.") }
        guard publication.conforms(to: .epub), !publication.readingOrder.isEmpty else { throw BookError.message("This publication has no readable EPUB chapters.") }
        return publication
    }
    static func makeEPUB(from textURL: URL, to output: URL, title: String) async throws {
        let data = try Data(contentsOf: textURL)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookError.message("The text file is empty or is not UTF-8/UTF-16 encoded.") }
        let temp = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func write(_ content: String, _ file: String) throws { try Data(content.utf8).write(to: temp.appendingPathComponent(file)) }
        try write("application/epub+zip", "mimetype")
        try write("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>", "META-INF/container.xml")
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let body = paragraphs.enumerated().map { "<p id=\"p\($0.offset)\">\(xml($0.element))</p>" }.joined(separator: "\n")
        try write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\"><head><title>\(xml(title))</title><style>body{line-height:1.6}p{white-space:pre-line}</style></head><body><h1>\(xml(title))</h1>\(body)</body></html>", "text.xhtml")
        try write("<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"text.xhtml\">\(xml(title))</a></li></ol></nav></body></html>", "nav.xhtml")
        try write("<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">\(SourceIdentity.hash(data))</dc:identifier><dc:title>\(xml(title))</dc:title><dc:language>en</dc:language><meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</meta></metadata><manifest><item id=\"text\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine><itemref idref=\"text\"/></spine></package>", "package.opf")
        let archive = try await Archive(url: output, accessMode: .create)
        try await archive.addEntry(with: "mimetype", relativeTo: temp, compressionMethod: .none)
        for file in ["META-INF/container.xml", "package.opf", "text.xhtml", "nav.xhtml"] { try await archive.addEntry(with: file, relativeTo: temp, compressionMethod: .deflate) }
    }
    static func validateArchive(_ url: URL) async throws {
        let archive: Archive
        do { archive = try await Archive(url: url, accessMode: .read) }
        catch Archive.ArchiveError.missingEndOfCentralDirectoryRecord {
            throw BookError.message("This EPUB is damaged or its download is incomplete. Download a fresh copy and try again. Your original file has not been changed.")
        }
        let entries = try await archive.entries()
        guard entries.count <= 20_000 else { throw BookError.message("This EPUB contains too many files.") }
        var total: UInt64 = 0
        var paths = Set<String>()
        for entry in entries {
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard !path.hasPrefix("/"), !path.contains(":"), !path.split(separator: "/").contains(".."), entry.type != .symlink, paths.insert(path).inserted else { throw BookError.message("This EPUB contains unsafe or duplicate archive paths.") }
            guard entry.uncompressedSize <= 100 * 1024 * 1024 else { throw BookError.message("An EPUB resource exceeds the 100 MB limit.") }
            total += entry.uncompressedSize
            guard total <= 1024 * 1024 * 1024 else { throw BookError.message("This EPUB exceeds the 1 GB expanded size limit.") }
        }
    }
    private static func xml(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}
