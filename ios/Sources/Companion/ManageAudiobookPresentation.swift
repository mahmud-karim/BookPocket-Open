import Foundation

enum ManageAudiobookSource {
    /// Page readiness uses only its immutable captured words. Setup still
    /// requires processed chapter coverage; unrelated page issues and voices do
    /// not become requirements for this exact selection.
    static func page(snapshot: ReaderScopeSnapshot, book: RemoteBook, chapterID: String, localSHA256: String,
                     cast: BookCast, voices: [RemoteVoice], engines: [RemoteEngine],
                     review: CastReviewInventory, statuses: [ChapterAnalysisStatus]) throws -> ReaderSourceSelection {
        let invalid = BookError.message("The captured page doesn't match the selected chapter's original source. Reopen this page and refresh its setup.")
        _ = try chapter(book: book, chapterID: chapterID, localSHA256: localSHA256)
        guard snapshot.hrefs.indices.contains(snapshot.current.resource),
              Set(snapshot.hrefs.map { ReaderSourceMapper.href($0) }).count == snapshot.hrefs.count,
              let selected = book.chapters.first(where: { $0.id == chapterID }) else { throw invalid }
        let capturedHref = snapshot.hrefs[snapshot.current.resource]
        guard ReaderSourceMapper.href(selected.href) == ReaderSourceMapper.href(capturedHref),
              book.chapters.filter({ ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(capturedHref) }).count == 1,
              let document = snapshot.documents[capturedHref], document.blocks.indices.contains(snapshot.current.block),
              document.blocks[snapshot.current.block].visible.contains(where: {
                  $0.start <= snapshot.current.offset && snapshot.current.offset < $0.end
              }) else { throw invalid }
        var page = snapshot
        page.scope = .page
        let selection = try ReaderSourceMapper.resolve(page, book: book)
        let owners = Set(selected.segments.map(\.id))
        guard !selection.ranges.isEmpty, selection.ranges.allSatisfy({ owners.contains($0.segmentId) }) else { throw invalid }
        try CastReview.validate(review, book: book)
        guard CastReview.chaptersNeedingAnalysis([chapterID], statuses: statuses, inventory: review).isEmpty else {
            throw BookError.message("Analyze this chapter before generating full cast audio.")
        }
        try CastReview.requireReady(review, book: book, ranges: selection.ranges)
        _ = try ReaderCastPlan.build(cast: cast, book: book, ranges: selection.ranges, voices: voices, engines: engines)
        return selection
    }
    static func chapter(book: RemoteBook, chapterID: String, localSHA256: String) throws -> ReaderSourceSelection {
        guard book.sourceSha256.lowercased() == localSHA256.lowercased(),
              book.chapters.filter({ $0.id == chapterID }).count == 1,
              let chapter = book.chapters.first(where: { $0.id == chapterID }),
              !chapter.segments.isEmpty,
              Set(book.segments.map(\.id)).count == book.segments.count,
              chapter.segments.allSatisfy({ !$0.text.isEmpty }) else {
            throw BookError.message("The selected chapter doesn't match this book's original source. Reopen the book and refresh its setup.")
        }
        return .init(title: chapter.title, ranges: chapter.segments.map { .init(segmentId: $0.id, startOffset: 0, endOffset: $0.text.unicodeScalars.count) }, excerpts: chapter.segments.map(\.text))
    }
}

/// Counts come from the selected chapter and saved source ranges, never from
/// the whole book or a made-up approximation of model elapsed time.
struct ManageAudiobookSummary {
    let missingVoiceCount: Int
    let pendingReviewCount: Int
    let needsAnalysis: Bool

    init(chapter: RemoteChapter, cast: BookCast, voices: [RemoteVoice], engines: [RemoteEngine],
         review: CastReviewInventory, statuses: [ChapterAnalysisStatus]) {
        let ranges = chapter.segments.map { SourceRange(segmentId: $0.id, startOffset: 0, endOffset: $0.text.unicodeScalars.count) }
        let pending = CastReview.pending(review, ranges: ranges)
        let segmentIDs = Set(chapter.segments.map(\.id))
        let required = Set(cast.assignments.filter { segmentIDs.contains($0.segmentId) }.map(\.characterId) +
            pending.compactMap(\.suggestedCharacterId) + ["narrator"])
        let narratorEngine = cast.characters.first { $0.id == "narrator" }?.voiceId.flatMap { id in voices.first { $0.id == id }?.engine }
        missingVoiceCount = required.filter { id in
            guard let voiceID = cast.characters.first(where: { $0.id == id })?.voiceId,
                  let voice = voices.first(where: { $0.id == voiceID }),
                  engines.contains(where: { $0.id == voice.engine && $0.available }) else { return true }
            return narratorEngine != nil && voice.engine != narratorEngine
        }.count
        pendingReviewCount = pending.count
        needsAnalysis = !CastReview.chaptersNeedingAnalysis([chapter.id], statuses: statuses, inventory: review).isEmpty
    }
}

struct ManageAnalysisProgress {
    let fraction: Double?
    let count: String
    let stage: String
    let finished: Bool
    let failed: Bool
    let step: Int

    init(job: AnalysisJob, mergingResults: Bool) {
        finished = job.status == "completed" && !mergingResults
        failed = job.status == "failed"
        let total = max(0, job.totalSegments)
        let completed = min(total, max(0, job.completedSegments))
        // Saving may already have processed all passages. Completion remains
        // separate until the server commits and the phone retrieves results.
        fraction = total > 0 ? Double(completed) / Double(total) : (finished ? 1 : nil)
        count = total > 0 ? "\(completed) of \(total) passages analyzed" : "Preparing chapter…"
        if failed { stage = "Analysis needs attention"; step = 1 }
        else if mergingResults || job.stage == "saving" { stage = "Saving cast suggestions"; step = 2 }
        else if finished { stage = "Analysis complete"; step = 3 }
        else if job.stage == "reading" { stage = "Reading chapter text"; step = 0 }
        else if job.status == "queued" || job.stage == "queued" { stage = "Waiting for your PC"; step = 0 }
        else { stage = "Identifying speakers"; step = 1 }
    }
}
