import Foundation

enum ManageAudiobookSource {
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
