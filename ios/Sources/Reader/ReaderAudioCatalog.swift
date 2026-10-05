import Foundation

/// Saved recordings are indexed by immutable source spans, independent of the
/// reader's font size, pagination, and whether a complete chapter exists.
struct ReaderAudioRecording: Identifiable {
    let job: RemoteJob
    let selection: ReaderSourceSelection
    let scope: NarrationScope
    let offline: Bool
    var id: String { job.id }
    var duration: Double { job.assets.reduce(0) { $0 + $1.duration } }
    var preview: String { selection.excerpts.first ?? "" }
}

enum ReaderAudioCatalog {
    static func recordings(book: RemoteBook, chapter: RemoteChapter, mode: ReaderVoiceMode,
                           jobs: [RemoteJob], localBookID: String,
                           downloads: (String) -> [DownloadRecord]) -> [ReaderAudioRecording] {
        jobs.compactMap { job in
            guard job.bookId == book.id, ReaderTakeMatch.mode(job) == mode,
                  job.status == "completed", job.completedSegments == job.segmentIds.count,
                  job.totalSegments == job.segmentIds.count,
                  job.assets.count == job.segmentIds.count,
                  Set(job.assets.map(\.id)).count == job.assets.count,
                  Set(job.assets.compactMap(\.segmentId)) == Set(job.segmentIds),
                  job.assets.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.bytes > 0 }),
                  (try? RangedAudioValidation.validate(job: job, book: book)) != nil,
                  let selection = selection(job: job, book: book),
                  selection.ranges.contains(where: { range in chapter.segments.contains { $0.id == range.segmentId } }) else { return nil }
            let chapterSelection = ReaderSourceSelection(title: chapter.title,
                ranges: chapter.segments.map { .init(segmentId: $0.id, startOffset: 0, endOffset: $0.text.unicodeScalars.count) },
                excerpts: chapter.segments.map(\.text))
            let scope: NarrationScope = ReaderTakeMatch.covers(job, book: book, selection: chapterSelection) ? .chapter : .page
            return ReaderAudioRecording(job: job, selection: selection, scope: scope,
                offline: ReaderTakeMatch.ready(job, book: book, selection: selection,
                    records: downloads(job.id), localBookID: localBookID))
        }.sorted { ($0.job.createdAt ?? "", $0.id) > ($1.job.createdAt ?? "", $1.id) }
    }

    static func selection(job: RemoteJob, book: RemoteBook) -> ReaderSourceSelection? {
        guard job.bookId == book.id, !job.segmentIds.isEmpty,
              Set(job.segmentIds).count == job.segmentIds.count else { return nil }
        var ranges: [SourceRange] = [], excerpts: [String] = []
        for segment in book.segments where job.segmentIds.contains(segment.id) {
            let range = job.sourceRanges?.first(where: { $0.segmentId == segment.id })
                ?? SourceRange(segmentId: segment.id, startOffset: 0, endOffset: segment.text.unicodeScalars.count)
            guard let indices = SourceIdentity.scalarRange(range.startOffset, range.endOffset, in: segment.text) else { return nil }
            ranges.append(range); excerpts.append(String(segment.text[indices]))
        }
        guard ranges.count == job.segmentIds.count else { return nil }
        return .init(title: "Saved recording", ranges: ranges, excerpts: excerpts)
    }
}
