import Foundation
import ReadiumShared

enum RecordedWordHighlight {
    /// Word precision comes only from measured alignment metadata. Silence is
    /// deliberately empty; never stretch a neighboring word across a pause.
    static func locator(record: DownloadRecord, seconds: Double) -> Locator? {
        guard seconds.isFinite, let segment = record.segment, var locator = segment.locator.locator else { return nil }
        let asset = record.asset
        let timing = asset.timings.first {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= asset.duration + 0.05
                && $0.startOffset >= (asset.sourceStart ?? 0) && $0.endOffset <= (asset.sourceEnd ?? segment.text.unicodeScalars.count)
                && $0.endOffset > $0.startOffset && $0.start <= seconds && seconds < $0.end
        }
        if asset.alignment == "word", timing == nil { return nil }
        let start = timing?.startOffset ?? asset.sourceStart ?? 0
        let end = timing?.endOffset ?? asset.sourceEnd ?? segment.text.unicodeScalars.count
        guard start < end, let range = SourceIdentity.scalarRange(start, end, in: segment.text) else { return nil }
        locator.text.highlight = String(segment.text[range])
        locator.text.before = String(segment.text[..<range.lowerBound].suffix(60))
        locator.text.after = String(segment.text[range.upperBound...].prefix(60))
        return locator
    }
}
