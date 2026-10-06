import XCTest
@testable import BookPocketOpen

private final class CastReviewTestProtocol: Foundation.URLProtocol {
    static var handle: ((URLRequest, Data) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            }
            let response = try Self.handle!(request, data)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.1); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CastReviewTests: XCTestCase {
    private let text = "🧭 Café: Mira said, “’Course, keep it steady.” Then Rowan whispered, ‘Wait.’"
    private var book: RemoteBook { .init(id: "review-book", title: "Original review", author: "Public test", language: "en", sourceSha256: SourceIdentity.hash(Data(text.utf8)), chapters: [.init(id: "chapter", title: "Chapter", href: "original.xhtml", segments: [.init(id: "source", text: text, kind: "paragraph", locator: .object([:]))])]) }
    private var issue: CastReviewIssue {
        let range = text.range(of: "“’Course, keep it steady.”")!
        return .init(id: "assignment:suggestion", chapterId: "chapter", segmentId: "source", startOffset: text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound), endOffset: text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound), sourceText: String(text[range]), reason: "unreviewed_assignment", message: "Who is speaking?", status: "pending")
    }
    private var inventory: CastReviewInventory { .init(bookId: book.id, sourceSha256: book.sourceSha256, revision: 4, issues: [issue]) }
    private var cast: BookCast {
        .init(characters: [.init(id: "narrator", name: "Narrator", aliases: [], voiceId: "kyon"), .init(id: "mira", name: "Mira", aliases: ["Captain"], voiceId: "mira-voice")], assignments: [.init(id: "reviewed", segmentId: issue.segmentId, startOffset: issue.startOffset, endOffset: issue.endOffset, characterId: "mira", confidence: 1, reviewed: true)])
    }
    private var result: CastReviewResult { var resolved = issue; resolved.status = "resolved"; return .init(revision: 5, issue: resolved, cast: cast) }
    func testReviewValidatesOriginalUnicodeScalarWordsAndSourceIdentity() throws {
        try CastReview.validate(inventory, book: book)
        XCTAssertEqual(String(text[try XCTUnwrap(SourceIdentity.scalarRange(issue.startOffset, issue.endOffset, in: text))]), issue.sourceText)
        var rewritten = inventory; rewritten.issues[0].sourceText = "Rewritten dialogue"
        XCTAssertThrowsError(try CastReview.validate(rewritten, book: book))
        rewritten = inventory; rewritten.sourceSha256 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try CastReview.validate(rewritten, book: book))
        rewritten = inventory; rewritten.issues[0].startOffset += 1
        XCTAssertThrowsError(try CastReview.validate(rewritten, book: book))
        XCTAssertEqual(book.segments[0].text, text)
        let base = URL(string: "https://review.invalid/phone")!
        let route = "/v1/books/review-book/review-issues/review:original/resolve"
        let url = try CompanionEndpoint.resource(route, base: base)
        XCTAssertEqual(url.path, "/phone" + route)
        XCTAssertTrue(CompanionEndpoint.allows(url, base: base))
        XCTAssertThrowsError(try CompanionEndpoint.resource("/v1/assets/review:original", base: base))
        XCTAssertThrowsError(try CompanionEndpoint.resource("/v1/books/review-book/review-issues/review:original/../resolve", base: base))
    }
    func testReviewOnlyBlocksExactSelectedSourceAndFailedManualCoverageSkipsModel() throws {
        let before = SourceRange(segmentId: "source", startOffset: 0, endOffset: issue.startOffset)
        try CastReview.requireReady(inventory, book: book, ranges: [before])
        let selected = SourceRange(segmentId: "source", startOffset: issue.startOffset, endOffset: issue.endOffset)
        XCTAssertThrowsError(try CastReview.requireReady(inventory, book: book, ranges: [selected]))
        var completed = inventory; completed.issues[0].status = "resolved"
        try CastReview.requireReady(completed, book: book, ranges: [selected])
        let failed = ChapterAnalysisStatus(chapterId: "chapter", status: "failed", analysisId: "old-model-failure", error: "Unsupported quote")
        XCTAssertEqual(CastReview.chaptersNeedingAnalysis(["chapter"], statuses: [failed], inventory: completed), [])
        var unknown = completed; unknown.issues = []
        XCTAssertEqual(CastReview.chaptersNeedingAnalysis(["chapter"], statuses: [failed], inventory: unknown), ["chapter"])
        let running = ChapterAnalysisStatus(chapterId: "chapter", status: "running", analysisId: "inflight", error: nil)
        XCTAssertEqual(CastReview.chaptersNeedingAnalysis(["chapter"], statuses: [running], inventory: completed), ["chapter"])
    }
    func testResolvedIssueRequiresFullReviewedCoverageAndExplicitVoice() throws {
        try CastReview.validateResolution(result, issue: issue, book: book)
        var invalid = result; invalid.cast.assignments[0].reviewed = false
        XCTAssertThrowsError(try CastReview.validateResolution(invalid, issue: issue, book: book))
        invalid = result; invalid.cast.assignments[0].startOffset += 1
        XCTAssertThrowsError(try CastReview.validateResolution(invalid, issue: issue, book: book))
        invalid = result; invalid.cast.characters[1].voiceId = nil
        XCTAssertThrowsError(try CastReview.validateResolution(invalid, issue: issue, book: book))
        var split = result
        let middle = issue.startOffset + 3
        split.cast.assignments = [.init(id: "narration", segmentId: "source", startOffset: issue.startOffset, endOffset: middle, characterId: "narrator", confidence: 1, reviewed: true), .init(id: "dialogue", segmentId: "source", startOffset: middle, endOffset: issue.endOffset, characterId: "mira", confidence: 1, reviewed: true)]
        try CastReview.validateResolution(split, issue: issue, book: book)
        let first = CastReviewRange(startOffset: issue.startOffset + 1, endOffset: middle, characterId: "mira")
        let second = CastReviewRange(startOffset: middle, endOffset: issue.endOffset - 1, characterId: "narrator")
        XCTAssertNil(CastReview.resolutionRanges(issue: issue, selected: first, additional: [second], narratorRemainder: false), "No silent narrator fill for prose gaps")
        let explicit = try XCTUnwrap(CastReview.resolutionRanges(issue: issue, selected: first, additional: [second], narratorRemainder: true))
        XCTAssertEqual(explicit.first?.characterId, "narrator"); XCTAssertEqual(explicit.last?.characterId, "narrator")
        XCTAssertEqual(explicit.first?.startOffset, issue.startOffset); XCTAssertEqual(explicit.last?.endOffset, issue.endOffset)
        XCTAssertNil(CastReview.resolutionRanges(issue: issue, selected: first, additional: [first, .init(startOffset: first.startOffset, endOffset: issue.endOffset, characterId: "narrator")], narratorRemainder: true), "Conflicting speaker ranges cannot be saved")
        invalid = result; invalid.cast.assignments.append(invalid.cast.assignments[0])
        XCTAssertThrowsError(try CastReview.validateResolution(invalid, issue: issue, book: book))
    }
    func testExplicitReviewReplacesUnchangedReviewedRangeAndPreservesConcurrentCastEdits() throws {
        var base = cast; base.assignments[0].characterId = "narrator"
        var local = base; local.characters[1].aliases = ["Saved captain", "Phone edit"]
        let merged = try CastReview.mergeResolution(base: base, local: local, result: result, issue: issue, book: book)
        XCTAssertEqual(merged.assignments, cast.assignments)
        XCTAssertEqual(merged.characters[1].aliases, local.characters[1].aliases)
        XCTAssertEqual(merged.characters[1].voiceId, "mira-voice")
        local.assignments[0].characterId = "mira"; local.assignments[0].confidence = 0.9
        let changed = try CastReview.mergeResolution(base: base, local: local, result: result, issue: issue, book: book)
        XCTAssertEqual(changed.assignments, local.assignments, "An edit made during the request remains an unsaved draft, not silently overwritten")
    }
    @MainActor func testReviewLostResponseRetainsExactRequestAcrossRestartWithoutDuplicatingCast() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); CastReviewTestProtocol.handle = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CastReviewTestProtocol.self]
        func client() throws -> CompanionClient { try CompanionClient(url: URL(string: "https://review.invalid")!, fingerprint: nil, token: "test-only-review", configuration: config) }
        let original = CastReviewRequest(requestId: UUID().uuidString.lowercased(), expectedRevision: 4, characterId: "mira", voiceId: "mira-voice")
        var calls: [CastReviewRequest] = []
        let response = result
        CastReviewTestProtocol.handle = { request, body in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-review")
            XCTAssertEqual(request.url!.path, "/v1/books/review-book/review-issues/assignment:suggestion/resolve")
            calls.append(try CompanionClient.decoder.decode(CastReviewRequest.self, from: body))
            if calls.count == 1 { throw URLError(.networkConnectionLost) }
            return (200, try CompanionClient.encoder.encode(response))
        }
        let first = CompanionStore(root: folder, client: try client())
        do { _ = try await first.resolveCastReview(issue, book: book, request: original); XCTFail("Lost confirmation should remain recoverable") } catch {}
        XCTAssertEqual(first.castReviewRequests.first?.request, original)
        let reopened = CompanionStore(root: folder, client: try client())
        var changed = original; changed.requestId = UUID().uuidString; changed.characterId = "narrator"; changed.voiceId = "kyon"
        let recovered = try await reopened.resolveCastReview(issue, book: book, request: changed)
        XCTAssertEqual(calls, [original, original]); XCTAssertEqual(recovered.cast, cast)
        XCTAssertTrue(reopened.castReviewRequests.isEmpty)
    }
    @MainActor func testReviewRevisionConflictPreservesDraftAndAllowsExplicitCurrentRevisionRetry() async throws {
        let draft = CastDraft()
        let service = CastService(fetch: { self.cast }, save: { _ in }, analyze: { _ in throw URLError(.unsupportedURL) }, poll: { _ in throw URLError(.unsupportedURL) }, requireReliableAnalysis: {})
        await draft.load(book: book, service: service)
        draft.value.characters[1].aliases.append("Unsaved")
        let before = draft.value
        let request = CastReviewRequest(requestId: UUID().uuidString, expectedRevision: 3, characterId: "mira", voiceId: "mira-voice")
        let rejected = await draft.resolve(issue: issue, book: book, request: request) { _ in throw CompanionHTTPError(statusCode: 409, detail: "Cast changed; choices retained") }
        XCTAssertNil(rejected); XCTAssertEqual(draft.value, before); XCTAssertTrue(draft.dirty)
        XCTAssertEqual(draft.error, "Cast changed; choices retained")
        let response = result
        let accepted = await draft.resolve(issue: issue, book: book, request: request) { _ in response }
        XCTAssertNotNil(accepted); XCTAssertEqual(draft.value.characters[1].aliases.last, "Unsaved"); XCTAssertTrue(draft.dirty)
    }
}
