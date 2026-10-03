import Foundation
import ReadiumShared
import ReadiumNavigator

extension ReaderModel {
    func captureScope(_ scope: NarrationScope) async throws -> ReaderScopeSnapshot {
        guard let navigator, let publication, let book, !capturingScope else { throw BookError.message("Wait for the current page to finish opening.") }
        capturingScope = true; defer { capturingScope = false }
        guard let viewport = navigator.viewport, viewport.resources.count == 1 else { throw BookError.message("This spread contains more than one resource. Switch to a single-page reading layout before generating narration.") }
        let links = publication.readingOrder
        let hrefs = links.map { ReaderSourceMapper.href($0.href) }
        let currentHref = ReaderSourceMapper.href(viewport.resources[0].href.string)
        guard let currentIndex = hrefs.firstIndex(of: currentHref), Set(hrefs).count == hrefs.count else { throw BookError.message("The current reading-order location is ambiguous. Open this chapter again from Contents.") }
        guard let scriptURL = Bundle.main.url(forResource: "ReaderScope", withExtension: "js") else { throw BookError.message("Reader source tools are unavailable. Reinstall the app.") }
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        func evaluate(_ expression: String) async throws -> SourceDocument {
            let result = try await navigator.evaluateJavaScript(script + "\nJSON.stringify(" + expression + ")").get()
            guard let json = result as? String else { throw BookError.message("This book's page could not be captured exactly.") }
            return try JSONDecoder().decode(SourceDocument.self, from: Data(json.utf8))
        }
        // Capture glyph visibility before presenting any sheet or contacting the PC.
        let isHTML = links[currentIndex].mediaType == .html || links[currentIndex].mediaType == .xhtml
        let visible = isHTML ? try await evaluate("bookPocketDocument(document, true)") : SourceDocument(blocks: [], anchors: [])
        guard navigator.viewport == viewport else {
            throw BookError.message("No stable visible text was found. Stop scrolling and try again on a text page.")
        }
        let first = visible.blocks.enumerated().first(where: { !$0.element.visible.isEmpty })
        if scope == .page && first == nil { throw BookError.message("There is no visible text on this page. Turn to a text page or generate its chapter.") }
        let current = SourcePoint(resource: currentIndex, block: first?.offset ?? 0, offset: first?.element.visible.first?.start ?? 0)
        var documents = [currentHref: visible]
        var boundaries: [ChapterBoundary] = []
        if scope == .chapter {
            func document(_ index: Int) async throws -> SourceDocument {
                let href = hrefs[index]
                if let cached = documents[href] { return cached }
                if let cached = sourceDocuments[href] { documents[href] = cached; return cached }
                let link = links[index]
                guard link.mediaType == .html || link.mediaType == .xhtml else {
                    let empty = SourceDocument(blocks: [], anchors: []); documents[href] = empty; return empty
                }
                guard let resource = publication.get(link) else { throw BookError.message("A chapter resource is missing from this book.") }
                let data = try await resource.read().get()
                guard data.count <= 20 * 1024 * 1024, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw BookError.message("This chapter's source encoding or size cannot be mapped safely. Generate its current page instead.") }
                let quoted = String(decoding: try JSONEncoder().encode(html), as: UTF8.self)
                let doc = try await evaluate("bookPocketDocument(new DOMParser().parseFromString(\(quoted), 'application/xhtml+xml'), false)")
                sourceDocuments[href] = doc; documents[href] = doc; return doc
            }
            func flatten(_ items: [ReadiumShared.Link]) -> [ReadiumShared.Link] { items.flatMap { [$0] + flatten($0.children) } }
            let toc = flatten(publication.manifest.tableOfContents)
            if toc.isEmpty && book.sourceFile.hasSuffix(".txt") {
                boundaries = [ChapterBoundary(title: book.title, point: SourcePoint(resource: 0, block: 0, offset: 0))]
            } else {
                for link in toc {
                    guard let index = hrefs.firstIndex(of: ReaderSourceMapper.href(link.href)) else { throw BookError.message("The table of contents refers outside the reading order. Generate the current page instead.") }
                    let fragment = link.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init)
                    let doc = fragment == nil || fragment == "" ? nil : try await document(index)
                    boundaries.append(ChapterBoundary(title: link.title ?? "Chapter", point: try ReaderSourceMapper.boundary(fragment: fragment, resource: index, document: doc)))
                }
            }
            let provisional = ReaderScopeSnapshot(scope: scope, hrefs: hrefs, documents: documents, current: current, boundaries: boundaries, isText: book.sourceFile.hasSuffix(".txt"))
            let (_, start, end) = try ReaderSourceMapper.chapterBounds(provisional)
            for index in start.resource...min(end.resource, hrefs.count - 1) { _ = try await document(index) }
        }
        return ReaderScopeSnapshot(scope: scope, hrefs: hrefs, documents: documents, current: current, boundaries: boundaries, isText: book.sourceFile.hasSuffix(".txt"))
    }
}
