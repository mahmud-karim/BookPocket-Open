import Foundation

/// Archive-specific validation. Network polling may legitimately expose an
/// unfinished job; a project claiming completion must contain its entire take.
enum ProjectImportValidation {
    static func validate(job: RemoteJob, book: RemoteBook) throws {
        let invalid = BookError.message("This project has an incomplete or conflicting narration manifest. Export a fresh production archive from your PC.")
        let segments = book.segments
        let selected = Set(job.segmentIds)
        let assetSegments = job.assets.compactMap(\.segmentId)
        guard job.bookId == book.id, !selected.isEmpty,
              selected.count == job.segmentIds.count,
              Set(segments.map(\.id)).count == segments.count,
              selected.isSubset(of: Set(segments.map(\.id))),
              Set(job.assets.map(\.id)).count == job.assets.count,
              assetSegments.count == job.assets.count,
              Set(assetSegments).count == assetSegments.count,
              Set(assetSegments).isSubset(of: selected) else { throw invalid }
        if job.status == "completed" {
            guard Set(assetSegments) == selected, job.completedSegments == selected.count,
                  job.totalSegments == selected.count else { throw invalid }
        }
        try RangedAudioValidation.validate(job: job, book: book)
        for asset in job.assets {
            guard let segment = segments.first(where: { $0.id == asset.segmentId }),
                  asset.bytes > 0, asset.duration.isFinite, asset.duration > 0 else { throw invalid }
            let selection = job.sourceRanges?.first { $0.segmentId == asset.segmentId }
            let start = selection?.startOffset ?? 0
            let end = selection?.endOffset ?? segment.text.unicodeScalars.count
            if let mode = asset.narrationMode, !["single", "full_cast"].contains(mode) { throw invalid }
            if let mode = asset.narrationMode, let expected = job.narrationMode, mode != expected { throw invalid }
            if asset.narrationMode == "single", asset.castSpans?.isEmpty == false { throw invalid }
            var castEnd = start
            for span in (asset.castSpans ?? []).sorted(by: { $0.startOffset < $1.startOffset }) {
                guard span.segmentId == segment.id, !span.voiceId.isEmpty, span.startOffset >= castEnd,
                      span.endOffset > span.startOffset, span.endOffset <= end else { throw invalid }
                castEnd = span.endOffset
            }
            for timing in (asset.sourceTimings ?? []) + asset.timings {
                guard timing.start.isFinite, timing.end.isFinite, timing.start >= 0,
                      timing.end > timing.start, timing.end <= asset.duration + 0.05,
                      timing.startOffset >= start, timing.endOffset <= end,
                      timing.endOffset > timing.startOffset else { throw invalid }
            }
        }
    }

    static func sameAudioIdentity(_ left: AudioAsset, _ right: AudioAsset) throws -> Bool {
        // A URL is a transport address, not part of the immutable recording.
        var original = left, normalized = right
        normalized.url = left.url
        normalized.sha256 = left.sha256
        guard left.sha256.lowercased() == right.sha256.lowercased() else { return false }
        // Older clients did not retain these optional provenance fields. Missing
        // metadata means unknown, not a contradictory empty cast or single mode.
        // Known values on both sides remain immutable, as do all source/audio data.
        if original.narrationMode == nil || normalized.narrationMode == nil { original.narrationMode = nil; normalized.narrationMode = nil }
        if original.castSpans == nil || normalized.castSpans == nil { original.castSpans = nil; normalized.castSpans = nil }
        return try CompanionClient.encoder.encode(original) == CompanionClient.encoder.encode(normalized)
    }
}
