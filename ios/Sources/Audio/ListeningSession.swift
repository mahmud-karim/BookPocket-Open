import Foundation

/// A local listening choice, independent of download/inventory ordering. Bounds
/// retain the exact recording selection; elapsed is its joined user timeline.
struct ListeningSession: Codable {
    struct Part: Codable {
        var recordID: String
        var sha256: String
        var sourceStart: Int?
        var sourceEnd: Int?
        var start: Double
        var end: Double?
    }
    var bookID: String
    var jobID: String?
    var parts: [Part]
    var elapsed: Double = 0
    var rate: Double = 1
    var miniPlayerDismissed = false
    var scope: String?
    var locatorJSON: String?

    init(bookID: String, jobID: String? = nil, selection: DownloadedRecordingSelection? = nil, scope: String? = nil) {
        self.bookID = bookID; self.jobID = jobID; self.scope = scope
        parts = selection.map { selection in zip(selection.records, selection.bounds).map {
            Part(recordID: $0.0.id, sha256: $0.0.asset.sha256, sourceStart: $0.0.asset.sourceStart, sourceEnd: $0.0.asset.sourceEnd, start: $0.1.start, end: $0.1.end)
        } } ?? []
    }
}
