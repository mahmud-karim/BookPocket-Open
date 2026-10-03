import Foundation
import ReadiumShared

enum NarrationScope: String, CaseIterable, Identifiable {
    case page, chapter
    var id: String { rawValue }
    var title: String { self == .page ? "Current page" : "Current chapter" }
}
struct ScalarInterval: Codable, Equatable { var start: Int; var end: Int }
struct SourceBlock: Codable { var text: String; var visible: [ScalarInterval] }
struct SourceAnchor: Codable { var id: String; var block: Int; var offset: Int }
struct SourceDocument: Codable { var blocks: [SourceBlock]; var anchors: [SourceAnchor] }
struct SourcePoint: Comparable, Equatable {
    var resource: Int; var block: Int; var offset: Int
    static func < (a: Self, b: Self) -> Bool { a.resource != b.resource ? a.resource < b.resource : a.block != b.block ? a.block < b.block : a.offset < b.offset }
}
struct ChapterBoundary { var title: String; var point: SourcePoint }
struct ReaderScopeSnapshot: Identifiable {
    var id = UUID()
    var scope: NarrationScope
    var hrefs: [String]
    var documents: [String: SourceDocument]
    var current: SourcePoint
    var boundaries: [ChapterBoundary]
    var isText: Bool
}
struct ReaderSourceSelection {
    var title: String
    var ranges: [SourceRange]
    var excerpts: [String]
    var text: String { excerpts.joined(separator: "\n\n") }
}

enum ReaderSourceMapper {
    static func href(_ value: String) -> String {
        let path = String(value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return path.removingPercentEncoding ?? path
    }
    static func boundary(fragment: String?, resource: Int, document: SourceDocument?) throws -> SourcePoint {
        guard let fragment, !fragment.isEmpty else { return SourcePoint(resource: resource, block: 0, offset: 0) }
        let matches = document?.anchors.filter { $0.id == (fragment.removingPercentEncoding ?? fragment) } ?? []
        guard matches.count == 1, let anchor = matches.first else { throw BookError.message("This chapter marker is missing or ambiguous. Open a chapter with a clear table-of-contents entry, or generate the current page.") }
        return SourcePoint(resource: resource, block: anchor.block, offset: anchor.offset)
    }
    static func chapterBounds(_ snapshot: ReaderScopeSnapshot) throws -> (String, SourcePoint, SourcePoint) {
        let boundaries = snapshot.boundaries
        guard !boundaries.isEmpty, zip(boundaries, boundaries.dropFirst()).allSatisfy({ $0.point <= $1.point }) else { throw BookError.message("The book's chapter order cannot be resolved safely. Use Current page instead.") }
        guard let index = boundaries.lastIndex(where: { $0.point <= snapshot.current }) else { throw BookError.message("This page is before the first chapter. Choose a chapter from Contents, or generate the current page.") }
        let start = boundaries[index].point
        let end = boundaries.dropFirst(index + 1).first(where: { $0.point > start })?.point ?? SourcePoint(resource: snapshot.hrefs.count, block: 0, offset: 0)
        return (boundaries[index].title, start, end)
    }
    static func resolve(_ snapshot: ReaderScopeSnapshot, book: RemoteBook) throws -> ReaderSourceSelection {
        var ranges: [SourceRange] = []; var excerpts: [String] = []
        var title = snapshot.scope.title
        let bounds = snapshot.scope == .chapter ? try chapterBounds(snapshot) : nil
        if let bounds { title = bounds.0 }
        for (resource, href) in snapshot.hrefs.enumerated() {
            if snapshot.scope == .page && resource != snapshot.current.resource { continue }
            if let bounds, resource < bounds.1.resource || resource > bounds.2.resource { continue }
            guard let document = snapshot.documents[href] else { throw BookError.message("The chapter source is incomplete. Reopen the reader and try again.") }
            let matches = book.chapters.filter { self.href($0.href) == self.href(href) }
            if document.blocks.isEmpty && matches.isEmpty { continue }
            guard matches.count == 1, let chapter = matches.first else { throw BookError.message("The PC copy's reading order does not match this book. Import its original file again.") }
            let shift = snapshot.isText && document.blocks.count == chapter.segments.count + 1 ? 1 : 0
            guard document.blocks.count - shift == chapter.segments.count,
                  zip(document.blocks.dropFirst(shift), chapter.segments).allSatisfy({ $0.text.unicodeScalars.elementsEqual($1.text.unicodeScalars) }) else { throw BookError.message("The displayed text does not match the PC's original source exactly. No audio was requested. Reimport the original book on the PC.") }
            for (index, segment) in chapter.segments.enumerated() {
                let domIndex = index + shift
                let block = document.blocks[domIndex]
                let count = segment.text.unicodeScalars.count
                var interval: ScalarInterval?
                if snapshot.scope == .page {
                    guard block.visible.count <= 1 else { throw BookError.message("This page contains hidden or separated text inside a passage. Its exact visible range cannot be narrated safely. Change the reading layout or generate its chapter.") }
                    interval = block.visible.first
                } else if let bounds {
                    let first = SourcePoint(resource: resource, block: domIndex, offset: 0)
                    let last = SourcePoint(resource: resource, block: domIndex, offset: count)
                    if last > bounds.1 && first < bounds.2 {
                        interval = ScalarInterval(start: resource == bounds.1.resource && domIndex == bounds.1.block ? bounds.1.offset : 0,
                                                  end: resource == bounds.2.resource && domIndex == bounds.2.block ? bounds.2.offset : count)
                    }
                }
                guard let interval, interval.start < interval.end else { continue }
                guard let range = SourceIdentity.scalarRange(interval.start, interval.end, in: segment.text) else { throw BookError.message("This page changed while its text was captured. Close this panel and try again.") }
                ranges.append(SourceRange(segmentId: segment.id, startOffset: interval.start, endOffset: interval.end))
                excerpts.append(String(segment.text[range]))
            }
        }
        guard !ranges.isEmpty else { throw BookError.message("There is no source text to narrate in this selection. Turn to a text page and try again.") }
        return ReaderSourceSelection(title: title, ranges: ranges, excerpts: excerpts)
    }
}
