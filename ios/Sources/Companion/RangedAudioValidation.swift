import Foundation

enum RangedAudioValidation {
    static func validate(job: RemoteJob, book: RemoteBook) throws {
        let invalid = BookError.message("This audio does not confirm the selected source range. Update the PC companion and regenerate it, or import a fresh production archive.")
        guard let ranges = job.sourceRanges, !ranges.isEmpty else {
            for asset in job.assets where asset.sourceStart != nil || asset.sourceEnd != nil {
                guard let segment = book.segments.first(where: { $0.id == asset.segmentId }),
                      asset.sourceStart == 0, asset.sourceEnd == segment.text.unicodeScalars.count else { throw invalid }
            }
            return
        }
        guard job.bookId == book.id, ranges.count == job.segmentIds.count,
              Set(ranges.map(\.segmentId)).count == ranges.count,
              Set(ranges.map(\.segmentId)) == Set(job.segmentIds),
              Set(job.assets.map(\.id)).count == job.assets.count,
              Set(job.assets.compactMap(\.segmentId)).count == job.assets.count else { throw invalid }
        for range in ranges {
            let matches = book.segments.filter { $0.id == range.segmentId }
            guard matches.count == 1, let text = matches.first?.text, range.startOffset < range.endOffset,
                  SourceIdentity.scalarRange(range.startOffset, range.endOffset, in: text) != nil else { throw invalid }
        }
        for asset in job.assets {
            guard let range = ranges.first(where: { $0.segmentId == asset.segmentId }),
                  asset.sourceStart == range.startOffset, asset.sourceEnd == range.endOffset,
                  asset.duration.isFinite, asset.duration > 0, asset.bytes > 0 else { throw invalid }
            if let mode = asset.narrationMode, let expected = job.narrationMode, mode != expected { throw invalid }
            let declared = job.narrationPlan?.filter { $0.segmentId == asset.segmentId }
            if let declared, (asset.castSpans ?? []) != declared { throw invalid }
            var end = range.startOffset
            for span in (asset.castSpans ?? []).sorted(by: { $0.startOffset < $1.startOffset }) {
                guard span.segmentId == asset.segmentId, span.startOffset >= end,
                      span.endOffset > span.startOffset, span.endOffset <= range.endOffset else { throw invalid }
                end = span.endOffset
            }
            for timing in asset.timings {
                guard timing.start.isFinite, timing.end.isFinite, timing.start >= 0, timing.end > timing.start,
                      timing.end <= asset.duration + 0.05,
                      timing.startOffset >= range.startOffset, timing.endOffset <= range.endOffset,
                      timing.endOffset > timing.startOffset else { throw invalid }
            }
        }
    }
}
