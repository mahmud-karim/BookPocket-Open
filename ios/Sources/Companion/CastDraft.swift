import Foundation
import Observation

enum CastMerge {
    static func equal(_ left: BookCast, _ right: BookCast) -> Bool {
        left.characters.sorted { $0.id < $1.id } == right.characters.sorted { $0.id < $1.id } &&
        left.assignments.sorted { $0.id < $1.id } == right.assignments.sorted { $0.id < $1.id }
    }
    static func overlaps(_ left: CastAssignment, _ right: CastAssignment) -> Bool {
        left.segmentId == right.segmentId && left.startOffset < right.endOffset && right.startOffset < left.endOffset
    }
    static func merge(base: BookCast, local: BookCast, remote: BookCast, book: RemoteBook) throws -> BookCast {
        if local.characters.isEmpty && local.assignments.isEmpty && (!base.characters.isEmpty || !base.assignments.isEmpty) { return BookCast() }
        let deletedCharacters = Set(base.characters.map(\.id)).subtracting(local.characters.map(\.id))
        let deletedRows = base.assignments.filter { old in !local.assignments.contains { $0.id == old.id } }
        let protected = local.assignments.filter { row in
            !deletedCharacters.contains(row.characterId) && (row.reviewed || base.assignments.first { $0.id == row.id } != row)
        }
        // A moved local row protects both its former and its new source span.
        // Tombstones are ranges, because a model may replace assignment IDs.
        let blocked = deletedRows + protected + base.assignments.filter { old in
            deletedCharacters.contains(old.characterId) || protected.contains { $0.id == old.id }
        }
        let protectedCharacters = Set(protected.map(\.characterId))
        var characters: [CastCharacter] = []
        let ids = remote.characters.map(\.id) + local.characters.map(\.id).filter { id in !remote.characters.contains { $0.id == id } }
        for id in ids where !deletedCharacters.contains(id) {
            let old = base.characters.first { $0.id == id }
            let current = local.characters.first { $0.id == id }
            let server = remote.characters.first { $0.id == id }
            if let current, let old, var merged = server {
                if current.name != old.name { merged.name = current.name }
                if current.aliases != old.aliases { merged.aliases = current.aliases }
                if current.voiceId != old.voiceId { merged.voiceId = current.voiceId }
                characters.append(merged)
            } else if let current, old == nil || current != old || protectedCharacters.contains(id) {
                characters.append(current)
            } else if let server { characters.append(server) }
        }
        let characterIDs = Set(characters.map(\.id))
        var assignments = remote.assignments.filter { row in
            characterIDs.contains(row.characterId) && !deletedCharacters.contains(row.characterId) &&
            !protected.contains(where: { $0.id == row.id }) && !blocked.contains(where: { overlaps($0, row) })
        }
        assignments += protected
        let order = Dictionary(book.segments.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        assignments.sort { (order[$0.segmentId] ?? Int.max, $0.startOffset, $0.id) < (order[$1.segmentId] ?? Int.max, $1.startOffset, $1.id) }
        guard characterIDs.count == characters.count, Set(assignments.map(\.id)).count == assignments.count else { throw invalid }
        for (index, row) in assignments.enumerated() {
            guard characterIDs.contains(row.characterId), row.startOffset < row.endOffset,
                  row.confidence.isFinite, let segment = book.segments.first(where: { $0.id == row.segmentId }),
                  SourceIdentity.scalarRange(row.startOffset, row.endOffset, in: segment.text) != nil,
                  !assignments.prefix(index).contains(where: { overlaps($0, row) }) else { throw invalid }
        }
        return BookCast(characters: characters, assignments: assignments)
    }
    private static var invalid: BookError { .message("The returned cast contains conflicting or invalid source ranges. Your local edits have been kept. Refresh the cast or review the analysis on your PC.") }
}

/// Injectable operations exercise delayed network arrivals in native tests using
/// the same draft controller as the UI, without advertising a test voice engine.
struct CastService {
    var fetch: () async throws -> BookCast
    var save: (BookCast) async throws -> Void
    var analyze: (CastAnalysisRequest) async throws -> AnalysisJob
    var poll: (String) async throws -> AnalysisJob
    var requireReliableAnalysis: () async throws -> Void
    var wait: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
}

@MainActor @Observable final class CastDraft {
    var value = BookCast()
    private(set) var saved = BookCast()
    private(set) var working = false
    private(set) var awaitingAnalysisConfirmation = false
    private var analysisBase: BookCast?
    private(set) var pendingAnalysisRequest: CastAnalysisRequest?
    var busy: Bool { working || analysisBase != nil || awaitingAnalysisConfirmation }
    var canResumeAnalysis: Bool { analysisBase != nil && !working && !awaitingAnalysisConfirmation }
    private(set) var loading = false
    private(set) var mergingResults = false
    private(set) var analysis: AnalysisJob?
    var error: String?
    var dirty: Bool { !CastMerge.equal(value, saved) }
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var analysisRequestID: UUID?

    func cancel() {
        operationID = nil; working = false; loading = false; mergingResults = false
        // The per-book controller and its draft survive sheet dismissal.
    }
    private func begin(resuming: Bool = false) -> UUID? {
        guard !working, resuming || !busy else { return nil }
        let id = UUID(); operationID = id; working = true; error = nil; return id
    }
    private func check(_ id: UUID) throws {
        guard operationID == id, !Task.isCancelled else { throw CancellationError() }
    }
    private func finish(_ id: UUID) {
        if operationID == id { operationID = nil; working = false; loading = false; mergingResults = false }
    }
    func load(book: RemoteBook, service: CastService) async {
        guard let id = begin(resuming: true) else { return }
        loading = true; let base = saved
        defer { finish(id) }
        do {
            while awaitingAnalysisConfirmation { try await service.wait(); try check(id) }
            if analysisBase != nil {
                loading = false
                if analysis == nil { try await confirmAnalysis(id: id, service: service) }
                try await resumeAnalysis(id: id, book: book, service: service)
                return
            }
            let remote = try await service.fetch(); try check(id)
            let merged = try CastMerge.merge(base: base, local: value, remote: remote, book: book)
            value = merged; saved = remote
        } catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
    }
    /// True means this exact draft was saved and no newer edits remain.
    func save(service: CastService) async -> Bool {
        guard let id = begin() else { return false }
        let snapshot = value
        defer { finish(id) }
        do {
            try await service.save(snapshot); try check(id)
            saved = snapshot
            if dirty { error = "Your earlier changes were saved. Save again to include the edits made while saving." }
            return !dirty
        } catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
        return false
    }
    func resolve(issue: CastReviewIssue, book: RemoteBook, request: CastReviewRequest,
                 operation: (CastReviewRequest) async throws -> CastReviewResult) async -> CastReviewResult? {
        guard let id = begin() else { return nil }
        let base = saved
        defer { finish(id) }
        do {
            let response = try await operation(request); try check(id)
            value = try CastReview.mergeResolution(base: base, local: value, result: response, issue: issue, book: book)
            saved = response.cast
            return response
        } catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
        return nil
    }
    func analyze(book: RemoteBook, hosted: Bool, service: CastService, chapterIDs: [String]? = nil, force: Bool = false) async {
        guard let id = begin() else { return }
        let base = value
        defer { finish(id) }
        do {
            try await service.requireReliableAnalysis(); try check(id)
            try await service.save(base); try check(id)
            saved = base
            analysisBase = base
            pendingAnalysisRequest = CastAnalysisRequest(requestId: UUID().uuidString.lowercased(), allowHosted: hosted, chapterIds: chapterIDs, forceReanalyze: force ? true : nil)
            analysis = nil
            try await confirmAnalysis(id: id, service: service, recovering: false)
            try await resumeAnalysis(id: id, book: book, service: service)
        } catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
    }
    /// Recover an already accepted server job after reopening the app. This
    /// never resubmits source text or changes the original hosted consent.
    func resumeExisting(book: RemoteBook, job: AnalysisJob, service: CastService) async {
        guard job.bookId == book.id, analysisBase == nil, !busy, let id = begin() else { return }
        analysisBase = saved; analysis = job
        defer { finish(id) }
        do { try await resumeAnalysis(id: id, book: book, service: service) }
        catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
    }
    private func confirmAnalysis(id: UUID, service: CastService, recovering: Bool = true) async throws {
        guard let request = pendingAnalysisRequest else { return }
        analysisRequestID = id; awaitingAnalysisConfirmation = true
        let started: AnalysisJob
        var submitted = false
        do {
            try await service.requireReliableAnalysis(); try check(id)
            submitted = true
            started = try await service.analyze(request)
        }
        catch {
            if analysisRequestID == id {
                awaitingAnalysisConfirmation = false; analysisRequestID = nil
                if !recovering && (!submitted || (error as? CompanionHTTPError)?.definitivelyRejected == true) {
                    // An explicit first-attempt rejection is not an uncertain
                    // accepted job. Recovery errors never discard its identity.
                    pendingAnalysisRequest = nil; analysisBase = nil
                }
            }
            // Keep the UUID, consent and original merge base. A retry must never
            // save the newer draft or start a second uncertain server job.
            throw error
        }
        // A late confirmation can retain the server ID after dismissal, but only
        // the current view operation may apply the eventual merged draft.
        guard analysisRequestID == id else { throw CancellationError() }
        analysisRequestID = nil; awaitingAnalysisConfirmation = false
        analysis = started
        try check(id)
    }
    private func resumeAnalysis(id: UUID, book: RemoteBook, service: CastService) async throws {
        guard let base = analysisBase, analysis != nil else { return }
        while let current = analysis, ["queued", "running"].contains(current.status) {
            try await service.wait(); try check(id)
            let updated = try await service.poll(current.id); try check(id)
            analysis = updated
        }
        mergingResults = true
        let remote = try await service.fetch(); try check(id)
        let merged = try CastMerge.merge(base: base, local: value, remote: remote, book: book)
        value = merged; saved = remote
        analysisBase = nil
        pendingAnalysisRequest = nil
    }
}
