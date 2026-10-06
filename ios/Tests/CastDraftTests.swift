import XCTest
@testable import BookPocketOpen

@MainActor private final class CastArrival<Value> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ name: String) { started = XCTestExpectation(description: name) }
    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func deliver(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

final class CastDraftTests: XCTestCase {
    @MainActor func testChapterScopedAnalysisKeepsReviewedOtherChapterAndExplicitVoiceChoices() async throws {
        var selected = book
        var second = selected.chapters[0]; second.id = "second"; second.segments[0].id = "second-source"; selected.chapters.append(second)
        let reviewed = row("first-reviewed", "“Go.”", reviewed: true)
        var suggestion = row("second-suggestion", "“Wait.”", character: "ivo"); suggestion.segmentId = "second-source"
        var server = BookCast(characters: characters, assignments: [reviewed])
        let draft = CastDraft(); var submitted: CastAnalysisRequest?
        let service = CastService(fetch: { server }, save: { server = $0 }, analyze: { request in
            submitted = request; if !server.assignments.contains(where: { $0.id == suggestion.id }) { server.assignments.append(suggestion) }
            return AnalysisJob(id: "chapter-analysis", bookId: selected.id, status: "completed", completedSegments: 1, totalSegments: 1, chapterIds: request.chapterIds)
        }, poll: { _ in throw URLError(.unsupportedURL) }, requireReliableAnalysis: {}, wait: {})
        await draft.load(book: selected, service: service)
        draft.value.characters[0].aliases = ["Saved captain"]
        await draft.analyze(book: selected, hosted: false, service: service, chapterIDs: [second.id])
        XCTAssertEqual(submitted?.chapterIds, [second.id]); XCTAssertNil(submitted?.forceReanalyze)
        XCTAssertEqual(draft.value.assignments.first { $0.id == reviewed.id }, reviewed)
        XCTAssertEqual(draft.value.assignments.first { $0.id == suggestion.id }, suggestion)
        XCTAssertEqual(draft.value.characters[0].aliases, ["Saved captain"])
        let narrator = RemoteVoice(id: "narrator", name: "Narrator", engine: "omnivoice", kind: "test-only", language: "en")
        let engine = RemoteEngine(id: "omnivoice", name: "Test engine", available: true, supportsCloning: true, languages: ["en"], license: "test-only")
        var cast = draft.value; cast.characters.append(.init(id: "narrator", name: "Narrator", aliases: [], voiceId: narrator.id))
        cast.assignments[1].reviewed = true
        let ranges = [SourceRange(segmentId: "second-source", startOffset: suggestion.startOffset, endOffset: suggestion.endOffset)]
        XCTAssertThrowsError(try ReaderCastPlan.build(cast: cast, book: selected, ranges: ranges, voices: [narrator], engines: [engine]), "Relevant missing voices require a deliberate choice")
        cast.characters[1].voiceId = narrator.id
        let plan = try ReaderCastPlan.build(cast: cast, book: selected, ranges: ranges, voices: [narrator], engines: [engine])
        XCTAssertEqual(plan.spans.map(\.voiceId), [narrator.id], "Use narrator is an explicit durable voice choice")
        XCTAssertEqual(selected.chapters[0].segments[0].text, text)
        await draft.analyze(book: selected, hosted: false, service: service, chapterIDs: [second.id], force: true)
        XCTAssertEqual(submitted?.forceReanalyze, true)
    }
    private let text = "“Mira 🧭 said, ‘stay.’” Then Ivo replied, “Go.” Later: “Wait.” Finally: “Rest.”"
    private var book: RemoteBook {
        RemoteBook(id: "cast-fixture", title: "Original cast fixture", author: "Test", language: "en", sourceSha256: SourceIdentity.hash(Data(text.utf8)), chapters: [.init(id: "chapter", title: "Original", href: "text.xhtml", segments: [.init(id: "source", text: text, kind: "paragraph", locator: .object([:]))])])
    }
    private var characters: [CastCharacter] {
        [.init(id: "mira", name: "Mira", aliases: ["Captain", "M"], voiceId: "original-voice"), .init(id: "ivo", name: "Ivo", aliases: [], voiceId: nil)]
    }
    private func row(_ id: String, _ words: String, character: String = "mira", reviewed: Bool = false) -> CastAssignment {
        let range = text.range(of: words)!
        return .init(id: id, segmentId: "source", startOffset: text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound), endOffset: text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound), characterId: character, confidence: 0.6, reviewed: reviewed)
    }
    private func job(_ status: String) -> AnalysisJob { AnalysisJob(id: "analysis", bookId: book.id, status: status, completedSegments: status == "completed" ? 1 : 0, totalSegments: 1, error: nil) }

    func testCharacterFieldsAliasRemovalAndDeletedCharactersWinIndependently() throws {
        var base = BookCast(characters: characters)
        base.characters.append(.init(id: "deleted", name: "Gone", aliases: [], voiceId: nil))
        var local = base; local.characters.removeLast()
        local.characters[0].name = "Mira the pilot"; local.characters[0].aliases = []; local.characters[0].voiceId = nil
        local.characters.append(.init(id: "manual", name: "Manual character", aliases: ["Chosen"], voiceId: "manual-voice"))
        var remote = base
        remote.characters[0].name = "Model name"; remote.characters[0].aliases.append("Model alias"); remote.characters[0].voiceId = "model-voice"
        remote.characters[1].aliases = ["Brother"]
        remote.characters.append(.init(id: "suggestion", name: "Suggested character", aliases: [], voiceId: nil))
        let merged = try CastMerge.merge(base: base, local: local, remote: remote, book: book)
        XCTAssertEqual(merged.characters.first { $0.id == "mira" }, local.characters[0])
        XCTAssertEqual(merged.characters.first { $0.id == "ivo" }?.aliases, ["Brother"])
        XCTAssertNil(merged.characters.first { $0.id == "deleted" })
        XCTAssertNotNil(merged.characters.first { $0.id == "manual" })
        XCTAssertNotNil(merged.characters.first { $0.id == "suggestion" })
        var nameOnly = base; nameOnly.characters[0].name = "Local name only"
        let partial = try CastMerge.merge(base: base, local: nameOnly, remote: remote, book: book)
        XCTAssertEqual(partial.characters[0].name, "Local name only")
        XCTAssertEqual(partial.characters[0].aliases, remote.characters[0].aliases)
        XCTAssertEqual(partial.characters[0].voiceId, "model-voice", "Untouched fields must still accept server changes")
    }

    func testNestedQuoteManualScalarRangeBlocksChangedModelIDsWithoutRewritingSource() throws {
        let base = BookCast(characters: characters, assignments: [row("old-outer", "“Mira 🧭 said, ‘stay.’”")])
        let manual = row("manual-inner", "🧭 said, ‘stay.’", reviewed: true)
        let local = BookCast(characters: characters, assignments: [manual])
        let later = row("new-outside", "“Go.”", character: "ivo")
        let remote = BookCast(characters: characters, assignments: [row("new-outer-id", "“Mira 🧭 said, ‘stay.’”"), later])
        let merged = try CastMerge.merge(base: base, local: local, remote: remote, book: book)
        XCTAssertEqual(merged.assignments, [manual, later])
        let range = try XCTUnwrap(SourceIdentity.scalarRange(manual.startOffset, manual.endOffset, in: text))
        XCTAssertEqual(String(text[range]), "🧭 said, ‘stay.’")
        XCTAssertEqual(NSRange(range, in: text).length, manual.endOffset - manual.startOffset + 1)
        XCTAssertEqual(book.segments[0].text, text)
        XCTAssertFalse(merged.assignments[1].reviewed, "New model proposals must remain unreviewed")
    }

    func testDeletedMovedAndReviewedRangesCannotBeReplacedByOverlappingProposals() throws {
        let deleted = row("deleted", "“Mira 🧭 said, ‘stay.’”")
        let old = row("moved", "“Go.”")
        let reviewed = row("reviewed", "“Rest.”", reviewed: true)
        let base = BookCast(characters: characters, assignments: [deleted, old, reviewed])
        let moved = row("moved", "“Wait.”", character: "ivo")
        let local = BookCast(characters: characters, assignments: [moved, reviewed])
        let remote = BookCast(characters: characters, assignments: [
            row("model-deleted", "“Mira 🧭 said, ‘stay.’”"), row("model-old", "“Go.”"),
            row("model-new", "“Wait.”"), row("model-reviewed", "“Rest.”", character: "ivo")
        ])
        XCTAssertEqual(try CastMerge.merge(base: base, local: local, remote: remote, book: book).assignments, [moved, reviewed])
        var deletedCharacter = base
        deletedCharacter.characters.removeAll { $0.id == "mira" }; deletedCharacter.assignments = []
        let result = try CastMerge.merge(base: base, local: deletedCharacter, remote: remote, book: book)
        XCTAssertTrue(result.assignments.isEmpty)
        XCTAssertEqual(result.characters.map(\.id), ["ivo"])
    }

    func testClearAllIsDistinctFromInitiallyEmptyCastAndInvalidRangesFailClosed() throws {
        let remote = BookCast(characters: characters, assignments: [row("proposal", "“Go.”")])
        XCTAssertEqual(try CastMerge.merge(base: remote, local: BookCast(), remote: remote, book: book), BookCast())
        XCTAssertTrue(CastMerge.equal(try CastMerge.merge(base: BookCast(), local: BookCast(), remote: remote, book: book), remote))
        var invalid = remote; invalid.assignments[0].endOffset = text.unicodeScalars.count + 1
        XCTAssertThrowsError(try CastMerge.merge(base: BookCast(), local: BookCast(), remote: invalid, book: book))
        invalid = remote; invalid.assignments[0].segmentId = "foreign-source"
        XCTAssertThrowsError(try CastMerge.merge(base: BookCast(), local: BookCast(), remote: invalid, book: book))
    }

    @MainActor func testDelayedInitialLoadAndSaveKeepEditsMadeAfterTheirSnapshots() async throws {
        let draft = CastDraft()
        let loaded = CastArrival<BookCast>("fetch entered")
        let saved = CastArrival<Bool>("save entered")
        var sent: [BookCast] = []
        let service = CastService(fetch: { await loaded.wait() }, save: { snapshot in sent.append(snapshot); _ = await saved.wait() }, analyze: { _ in self.job("completed") }, poll: { _ in self.job("completed") }, requireReliableAnalysis: {})
        let loading = Task { await draft.load(book: book, service: service) }
        await fulfillment(of: [loaded.started], timeout: 5)
        draft.value.characters.append(.init(id: "typed-first", name: "Typed while loading", aliases: [], voiceId: nil))
        loaded.deliver(BookCast(characters: characters))
        await loading.value
        XCTAssertEqual(Set(draft.value.characters.map(\.id)), ["mira", "ivo", "typed-first"])
        XCTAssertTrue(draft.dirty)
        let saving = Task { await draft.save(service: service) }
        await fulfillment(of: [saved.started], timeout: 5)
        let index = try XCTUnwrap(draft.value.characters.firstIndex { $0.id == "mira" })
        draft.value.characters[index].aliases = []
        saved.deliver(true)
        let closed = await saving.value
        XCTAssertFalse(closed, "Save & close must not dismiss newer unsaved edits")
        XCTAssertEqual(sent[0].characters.first { $0.id == "mira" }?.aliases, ["Captain", "M"])
        XCTAssertEqual(draft.value.characters[index].aliases, [])
        XCTAssertTrue(draft.dirty)
    }

    @MainActor func testDelayedAnalysisMergesEditsWithoutAutosavingModelSuggestions() async throws {
        let draft = CastDraft()
        let base = BookCast(characters: characters, assignments: [row("old-outer", "“Mira 🧭 said, ‘stay.’”")])
        let arrival = CastArrival<AnalysisJob>("analysis poll entered")
        let finalArrival = CastArrival<BookCast>("final cast fetch entered")
        var server = base; var writes: [BookCast] = []; var fetches = 0
        let service = CastService(fetch: { fetches += 1; if fetches == 1 { return base }; return await finalArrival.wait() }, save: { writes.append($0) }, analyze: { _ in self.job("running") }, poll: { _ in await arrival.wait() }, requireReliableAnalysis: {}, wait: {})
        await draft.load(book: book, service: service)
        let analyzing = Task { await draft.analyze(book: book, hosted: false, service: service) }
        await fulfillment(of: [arrival.started], timeout: 5)
        let manual = row("manual", "🧭 said, ‘stay.’", reviewed: true)
        draft.value.assignments = [manual]; draft.value.characters[0].aliases = []
        server.assignments = [row("replacement-id", "“Mira 🧭 said, ‘stay.’”"), row("outside", "“Go.”", character: "ivo")]
        arrival.deliver(job("completed"))
        await fulfillment(of: [finalArrival.started], timeout: 5)
        XCTAssertTrue(draft.busy)
        XCTAssertTrue(draft.mergingResults)
        draft.value.characters[0].voiceId = nil
        finalArrival.deliver(server); await analyzing.value
        XCTAssertEqual(draft.value.assignments.map(\.id), ["manual", "outside"])
        XCTAssertEqual(draft.value.characters[0].aliases, [])
        XCTAssertNil(draft.value.characters[0].voiceId)
        XCTAssertTrue(draft.dirty)
        XCTAssertEqual(writes, [base], "Only the user's start snapshot is sent; merged model suggestions are not auto-saved")
        XCTAssertFalse(draft.value.assignments[1].reviewed)
    }

    @MainActor func testCancelledOldArrivalCannotOverwriteReopenedPerBookDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionStore(root: root)
        let draft = store.castDraft(for: book.id)
        let arrival = CastArrival<BookCast>("old fetch entered")
        let base = BookCast(characters: characters)
        let old = CastService(fetch: { await arrival.wait() }, save: { _ in }, analyze: { _ in self.job("completed") }, poll: { _ in self.job("completed") }, requireReliableAnalysis: {})
        let loading = Task { await draft.load(book: book, service: old) }
        await fulfillment(of: [arrival.started], timeout: 5)
        draft.value = base; draft.value.characters[0].name = "Kept locally"
        loading.cancel(); draft.cancel()
        let reopened = store.castDraft(for: book.id)
        XCTAssertTrue(reopened === draft)
        var fresh = old; fresh.fetch = { base }
        await reopened.load(book: book, service: fresh)
        let beforeLateArrival = reopened.value
        arrival.deliver(BookCast()); await loading.value
        XCTAssertEqual(reopened.value, beforeLateArrival)
        XCTAssertEqual(reopened.value.characters.first { $0.id == "mira" }?.name, "Kept locally")
        XCTAssertTrue(reopened.dirty)
        XCTAssertFalse(reopened.busy)
        XCTAssertFalse(store.castDraft(for: "another-book") === draft)
    }

    @MainActor func testCancelledAnalysisResumesSameJobAndRetriesFinalFetchWithOriginalBase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionStore(root: root)
        let draft = store.castDraft(for: book.id)
        let base = BookCast(characters: characters, assignments: [row("outer", "“Mira 🧭 said, ‘stay.’”")])
        let oldPoll = CastArrival<AnalysisJob>("old analysis poll")
        var writes = 0; var submissions = 0; var polled: [String] = []
        var service = CastService(fetch: { base }, save: { _ in writes += 1 }, analyze: { _ in submissions += 1; return self.job("running") }, poll: { id in polled.append(id); return await oldPoll.wait() }, requireReliableAnalysis: {}, wait: {})
        await draft.load(book: book, service: service)
        let first = Task { await draft.analyze(book: book, hosted: false, service: service) }
        await fulfillment(of: [oldPoll.started], timeout: 5)
        draft.value.characters[0].aliases = []
        first.cancel(); draft.cancel()
        XCTAssertTrue(draft.busy, "Pending server analysis must continue to block whole-cast writes after dismissal")
        XCTAssertTrue(draft.canResumeAnalysis)
        let blockedSave = await draft.save(service: service)
        XCTAssertFalse(blockedSave)
        await draft.analyze(book: book, hosted: false, service: service)
        XCTAssertEqual(writes, 1); XCTAssertEqual(submissions, 1)

        let reopened = store.castDraft(for: book.id)
        service.poll = { id in polled.append(id); return self.job("completed") }
        service.fetch = { throw URLError(.networkConnectionLost) }
        await reopened.load(book: book, service: service)
        XCTAssertEqual(polled, ["analysis", "analysis"])
        XCTAssertTrue(reopened.canResumeAnalysis)
        XCTAssertTrue(reopened.busy)
        XCTAssertNotNil(reopened.error)
        XCTAssertEqual(reopened.value.characters[0].aliases, [])
        oldPoll.deliver(job("running")); await first.value
        XCTAssertEqual(reopened.analysis?.status, "completed", "The obsolete poll must not revert the resumed job")

        let finalArrival = CastArrival<BookCast>("retry final fetch")
        service.fetch = { await finalArrival.wait() }
        let retry = Task { await reopened.load(book: book, service: service) }
        await fulfillment(of: [finalArrival.started], timeout: 5)
        let manual = row("manual-after-reopen", "🧭 said, ‘stay.’", reviewed: true)
        reopened.value.assignments = [manual]
        let remote = BookCast(characters: characters, assignments: [row("new-outer-id", "“Mira 🧭 said, ‘stay.’”"), row("outside", "“Go.”", character: "ivo")])
        finalArrival.deliver(remote); await retry.value
        XCTAssertEqual(reopened.value.assignments.map(\.id), [manual.id, "outside"])
        XCTAssertEqual(reopened.value.characters[0].aliases, [])
        XCTAssertTrue(reopened.dirty)
        XCTAssertFalse(reopened.busy)
        XCTAssertFalse(reopened.canResumeAnalysis)
        XCTAssertEqual(writes, 1); XCTAssertEqual(submissions, 1)
        XCTAssertEqual(polled.count, 2, "Retrying a terminal result fetch must not submit or restart analysis")
    }

    @MainActor func testDismissalDuringConfirmationRetainsReturnedAnalysisIDForReopen() async throws {
        let draft = CastDraft()
        let base = BookCast(characters: characters)
        let confirmation = CastArrival<AnalysisJob>("analysis confirmation")
        let reopenedWait = CastArrival<Bool>("reopen awaiting confirmation")
        var submissions = 0; var writes = 0; var waits = 0
        var service = CastService(fetch: { base }, save: { _ in writes += 1 }, analyze: { _ in submissions += 1; return await confirmation.wait() }, poll: { id in XCTAssertEqual(id, "analysis"); return self.job("completed") }, requireReliableAnalysis: {}, wait: {})
        await draft.load(book: book, service: service)
        let starting = Task { await draft.analyze(book: book, hosted: false, service: service) }
        await fulfillment(of: [confirmation.started], timeout: 5)
        XCTAssertTrue(draft.awaitingAnalysisConfirmation)
        // The view invalidates its operation but deliberately does not cancel
        // this short POST until its server identity has been received.
        draft.cancel(); draft.value.characters[0].name = "Edited after dismissal"
        service.wait = { waits += 1; if waits == 1 { _ = await reopenedWait.wait() } }
        let reopening = Task { await draft.load(book: book, service: service) }
        await fulfillment(of: [reopenedWait.started], timeout: 5)
        confirmation.deliver(job("running")); await starting.value
        XCTAssertEqual(draft.analysis?.id, "analysis")
        XCTAssertTrue(draft.busy)
        reopenedWait.deliver(true); await reopening.value
        XCTAssertEqual(draft.value.characters[0].name, "Edited after dismissal")
        XCTAssertTrue(draft.dirty)
        XCTAssertFalse(draft.busy)
        XCTAssertEqual(submissions, 1); XCTAssertEqual(writes, 1)
    }

    @MainActor func testAcceptedButLostConfirmationRecoversSameRequestConsentAndMergeBase() async throws {
        let draft = CastDraft()
        let base = BookCast(characters: characters, assignments: [row("old-outer", "“Mira 🧭 said, ‘stay.’”")])
        var server = base
        var requests: [CastAnalysisRequest] = []
        var accepted: [String: Bool] = [:]
        var writes: [BookCast] = []
        var loseFirstResponse = true
        var capability = true
        let service = CastService(fetch: { server }, save: { writes.append($0) }, analyze: { request in
            requests.append(request)
            if let consent = accepted[request.requestId] { XCTAssertEqual(consent, request.allowHosted) }
            else { accepted[request.requestId] = request.allowHosted }
            server.assignments = [self.row("new-outer-id", "“Mira 🧭 said, ‘stay.’”"), self.row("outside", "“Go.”", character: "ivo")]
            if loseFirstResponse { loseFirstResponse = false; throw URLError(.networkConnectionLost) }
            var result = self.job("completed"); result.id = request.requestId
            return result
        }, poll: { _ in XCTFail("The recovered job is already terminal"); return self.job("completed") }, requireReliableAnalysis: {
            if !capability { throw BookError.message("Update PC Companion for reliable analysis requests.") }
        }, wait: {})
        await draft.load(book: book, service: service)
        await draft.analyze(book: book, hosted: true, service: service)
        let pending = try XCTUnwrap(draft.pendingAnalysisRequest)
        XCTAssertNotNil(UUID(uuidString: pending.requestId))
        XCTAssertTrue(pending.allowHosted)
        XCTAssertTrue(draft.busy)
        XCTAssertTrue(draft.canResumeAnalysis)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(writes, [base])

        draft.value.characters[0].aliases = []
        let manual = row("manual-after-loss", "🧭 said, ‘stay.’", reviewed: true)
        draft.value.assignments = [manual]
        draft.cancel() // Same in-memory per-book draft is reopened.
        await draft.analyze(book: book, hosted: false, service: service)
        let savedWhilePending = await draft.save(service: service)
        XCTAssertFalse(savedWhilePending)
        XCTAssertEqual(requests.count, 1)
        capability = false
        await draft.load(book: book, service: service)
        XCTAssertEqual(requests.count, 1, "An older PC must not receive an uncertain retry")
        XCTAssertTrue(draft.error?.contains("Update PC Companion") == true)
        XCTAssertEqual(draft.pendingAnalysisRequest, pending)

        capability = true
        await draft.load(book: book, service: service)
        XCTAssertEqual(requests, [pending, pending], "Recovery must retain UUID and original hosted consent")
        XCTAssertEqual(accepted.count, 1, "The accepted logical request must not duplicate")
        XCTAssertEqual(writes, [base], "Recovery must not PUT the newer human draft over server analysis")
        XCTAssertEqual(draft.value.assignments.map(\.id), [manual.id, "outside"])
        XCTAssertEqual(draft.value.characters[0].aliases, [])
        XCTAssertTrue(draft.dirty)
        XCTAssertFalse(draft.busy)
        XCTAssertNil(draft.pendingAnalysisRequest)
        await draft.analyze(book: book, hosted: false, service: service)
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(requests[2].requestId, pending.requestId, "A deliberate analysis after known completion gets a fresh identity")
        XCTAssertFalse(requests[2].allowHosted)
        XCTAssertEqual(accepted.count, 2)
        XCTAssertEqual(writes.count, 2)
    }

    @MainActor func testOlderCompanionIsRejectedBeforeSavingAnalysisStartSnapshot() async {
        let draft = CastDraft(); draft.value = BookCast(characters: characters)
        var saves = 0; var submissions = 0
        let service = CastService(fetch: { BookCast() }, save: { _ in saves += 1 }, analyze: { _ in submissions += 1; return self.job("completed") }, poll: { _ in self.job("completed") }, requireReliableAnalysis: { throw BookError.message("Update PC Companion for reliable analysis requests.") })
        await draft.analyze(book: book, hosted: false, service: service)
        XCTAssertEqual(saves, 0); XCTAssertEqual(submissions, 0)
        XCTAssertNil(draft.pendingAnalysisRequest)
        XCTAssertTrue(draft.error?.contains("Update PC Companion") == true)
        XCTAssertEqual(draft.value.characters, characters)
    }

    @MainActor func testInitialExplicitRejectionReleasesAttemptButRecoveryErrorsRetainIt() async throws {
        for status in [400, 401, 403, 404, 409, 422, 408, 429, 500, 503] {
            let draft = CastDraft(); draft.value = BookCast(characters: characters)
            var requests: [CastAnalysisRequest] = []
            var responseStatus = status
            let service = CastService(fetch: { BookCast(characters: self.characters) }, save: { _ in }, analyze: { request in
                requests.append(request)
                throw CompanionHTTPError(statusCode: responseStatus, detail: "Explicit test response \(responseStatus)")
            }, poll: { _ in self.job("completed") }, requireReliableAnalysis: {})
            await draft.analyze(book: book, hosted: false, service: service)
            let rejected = (400..<500).contains(status) && ![408, 429].contains(status)
            XCTAssertEqual(draft.pendingAnalysisRequest == nil, rejected, "HTTP \(status)")
            XCTAssertEqual(draft.busy, !rejected, "HTTP \(status)")
            if !rejected {
                let pending = try XCTUnwrap(draft.pendingAnalysisRequest)
                responseStatus = 409
                await draft.load(book: book, service: service)
                XCTAssertEqual(draft.pendingAnalysisRequest, pending, "A conflict during uncertain recovery must not release the original identity")
                XCTAssertEqual(requests, [pending, pending])
                XCTAssertTrue(draft.busy)
            }
        }
    }

    @MainActor func testEditsDuringCapabilityCheckRemainUnsavedAndMergeAgainstStartSnapshot() async throws {
        let draft = CastDraft(); let base = BookCast(characters: characters); draft.value = base
        let capability = CastArrival<Bool>("initial capability check")
        var checks = 0; var writes: [BookCast] = []
        let service = CastService(fetch: { base }, save: { writes.append($0) }, analyze: { _ in self.job("completed") }, poll: { _ in self.job("completed") }, requireReliableAnalysis: {
            checks += 1
            if checks == 1 { _ = await capability.wait() }
        })
        let analysis = Task { await draft.analyze(book: book, hosted: false, service: service) }
        await fulfillment(of: [capability.started], timeout: 5)
        draft.value.characters[0].name = "Typed during capability check"
        draft.value.characters[0].aliases = []
        capability.deliver(true); await analysis.value
        XCTAssertEqual(writes, [base])
        XCTAssertEqual(draft.saved, base)
        XCTAssertEqual(draft.value.characters[0].name, "Typed during capability check")
        XCTAssertEqual(draft.value.characters[0].aliases, [])
        XCTAssertTrue(draft.dirty)
    }
}
