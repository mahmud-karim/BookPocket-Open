import Foundation

struct DownloadedRecordingSelection {
    var records: [DownloadRecord]
    var bounds: [(start: Double, end: Double?)]
    var id: String {
        zip(records, bounds).map { "\($0.0.id):\($0.1.start):\($0.1.end.map { String($0) } ?? "end")" }.joined(separator: "|")
    }
    var duration: Double { zip(records, bounds).reduce(0) { $0 + (($1.1.end ?? $1.0.asset.duration) - $1.1.start) } }

    /// Only timestamps supplied by the recording can trim a wider take. No
    /// proportional text/audio guessing, nor neighboring source segments.
    static func reader(job: RemoteJob, selection: ReaderSourceSelection, records: [DownloadRecord]) throws -> Self {
        var chosen: [DownloadRecord] = [], bounds: [(Double, Double?)] = []
        for range in selection.ranges {
            guard let record = records.first(where: { $0.jobID == job.id && $0.asset.segmentId == range.segmentId }), let segment = record.segment else { throw BookError.message("Some audio is missing. Reconnect your PC and retry its download.") }
            let declared = job.sourceRanges?.first { $0.segmentId == range.segmentId }
            let assetStart = record.asset.sourceStart ?? declared?.startOffset ?? 0
            let assetEnd = record.asset.sourceEnd ?? declared?.endOffset ?? segment.text.unicodeScalars.count
            guard range.startOffset >= assetStart, range.endOffset <= assetEnd, range.endOffset > range.startOffset else { throw BookError.message("This recording does not cover the selected words.") }
            var start = 0.0, end: Double? = nil
            let timingEvidence = (record.asset.sourceTimings ?? []) + record.asset.timings
            if range.startOffset != assetStart {
                guard let timing = timingEvidence.first(where: { $0.startOffset == range.startOffset }) else { throw BookError.message("Generate this page to play exactly its words. This older recording has no timing at the page boundary.") }
                start = timing.start
            }
            if range.endOffset != assetEnd {
                guard let timing = timingEvidence.first(where: { $0.endOffset == range.endOffset }) else { throw BookError.message("Generate this page to play exactly its words. This older recording has no timing at the page boundary.") }
                end = timing.end
            }
            guard start.isFinite, start >= 0, (end ?? record.asset.duration).isFinite, (end ?? record.asset.duration) > start,
                  (end ?? record.asset.duration) <= record.asset.duration + 0.05 else { throw BookError.message("Recording timing is invalid. Retry its download.") }
            chosen.append(record); bounds.append((start, end))
        }
        guard !chosen.isEmpty else { throw BookError.message("No audio is available for this selection.") }
        return Self(records: chosen, bounds: bounds)
    }
}
