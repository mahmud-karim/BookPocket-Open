import Foundation

enum CastReview {
    static func chaptersNeedingAnalysis(_ chapters: [String], statuses: [ChapterAnalysisStatus], inventory: CastReviewInventory) -> [String] {
        chapters.filter { chapter in !statuses.contains { status in
            status.chapterId == chapter && (status.status == "completed" || status.manualReady == true ||
                (status.status == "failed" && inventory.issues.contains { $0.chapterId == chapter && ["ambiguous_quotation", "unreviewed_assignment", "analysis_failed"].contains($0.reason) }))
        } }
    }
    static func validate(_ inventory: CastReviewInventory, book: RemoteBook) throws {
        guard inventory.bookId == book.id, inventory.sourceSha256.lowercased() == book.sourceSha256.lowercased(), inventory.revision >= 0,
              Set(inventory.issues.map(\.id)).count == inventory.issues.count else { throw invalid }
        for issue in inventory.issues {
            guard ["pending", "resolved"].contains(issue.status),
                  let chapter = book.chapters.first(where: { $0.id == issue.chapterId }),
                  let segment = chapter.segments.first(where: { $0.id == issue.segmentId }),
                  issue.startOffset < issue.endOffset,
                  let range = SourceIdentity.scalarRange(issue.startOffset, issue.endOffset, in: segment.text),
                  String(segment.text[range]) == issue.sourceText else { throw invalid }
        }
    }
    static func pending(_ inventory: CastReviewInventory, ranges: [SourceRange]?) -> [CastReviewIssue] {
        inventory.issues.filter { issue in issue.status == "pending" && (ranges == nil || ranges!.contains {
            $0.segmentId == issue.segmentId && $0.startOffset < issue.endOffset && issue.startOffset < $0.endOffset
        }) }
    }
    static func requireReady(_ inventory: CastReviewInventory, book: RemoteBook, ranges: [SourceRange]) throws {
        try validate(inventory, book: book)
        guard pending(inventory, ranges: ranges).isEmpty else {
            throw BookError.message("Review the unclear dialogue in these words before generating. Choose who speaks and save their voice.")
        }
    }
    static func validateResolution(_ result: CastReviewResult, issue: CastReviewIssue, book: RemoteBook) throws {
        _ = try CastMerge.merge(base: BookCast(), local: BookCast(), remote: result.cast, book: book)
        guard result.issue.id == issue.id, result.issue.segmentId == issue.segmentId,
              result.issue.startOffset == issue.startOffset, result.issue.endOffset == issue.endOffset,
              result.issue.sourceText == issue.sourceText, result.issue.status == "resolved" else { throw invalid }
        try validate(.init(bookId: book.id, sourceSha256: book.sourceSha256, revision: result.revision, issues: [result.issue]), book: book)
        let rows = result.cast.assignments.filter { $0.segmentId == issue.segmentId && $0.startOffset < issue.endOffset && issue.startOffset < $0.endOffset }.sorted { $0.startOffset < $1.startOffset }
        var covered = issue.startOffset
        for row in rows {
            guard row.reviewed, row.startOffset <= covered, row.endOffset > covered,
                  result.cast.characters.contains(where: { $0.id == row.characterId && $0.voiceId?.isEmpty == false }) else { throw invalid }
            covered = row.endOffset
        }
        guard covered >= issue.endOffset else { throw invalid }
    }
    static func resolutionRanges(issue: CastReviewIssue, selected: CastReviewRange?, additional: [CastReviewRange], narratorRemainder: Bool) -> [CastReviewRange]? {
        var rows = additional
        if let selected, !rows.contains(selected) { rows.append(selected) }
        rows.sort { $0.startOffset < $1.startOffset }
        guard !rows.isEmpty else { return nil }
        var result: [CastReviewRange] = [], cursor = issue.startOffset
        for row in rows {
            guard !row.characterId.isEmpty, row.startOffset >= cursor, row.endOffset > row.startOffset, row.endOffset <= issue.endOffset else { return nil }
            if row.startOffset > cursor {
                guard narratorRemainder else { return nil }
                result.append(.init(startOffset: cursor, endOffset: row.startOffset, characterId: "narrator"))
            }
            result.append(row); cursor = row.endOffset
        }
        if cursor < issue.endOffset {
            guard narratorRemainder else { return nil }
            result.append(.init(startOffset: cursor, endOffset: issue.endOffset, characterId: "narrator"))
        }
        return result
    }
    static func mergeResolution(base: BookCast, local: BookCast, result: CastReviewResult, issue: CastReviewIssue, book: RemoteBook) throws -> BookCast {
        try validateResolution(result, issue: issue, book: book)
        // This explicit review authorizes replacing the unchanged rows in this
        // issue. Edits made while the save was in flight remain protected.
        let replaced = Set(base.assignments.filter { old in
            old.segmentId == issue.segmentId && old.startOffset < issue.endOffset && issue.startOffset < old.endOffset && local.assignments.contains(old)
        }.map(\.id))
        var mergeBase = base, mergeLocal = local
        mergeBase.assignments.removeAll { replaced.contains($0.id) }
        mergeLocal.assignments.removeAll { replaced.contains($0.id) }
        return try CastMerge.merge(base: mergeBase, local: mergeLocal, remote: result.cast, book: book)
    }
    private static var invalid: BookError { .message("This review does not match the original book or its saved speaker ranges. Refresh the review; your changes have been kept.") }
}
