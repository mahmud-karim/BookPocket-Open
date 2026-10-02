import XCTest
@testable import BookPocketOpen

final class CompanionContractTests: XCTestCase {
    func testAnalysisWarningsAreAdditiveAndRemainVisibleToReview() throws {
        let base = #"{"id":"analysis","book_id":"book","status":"completed","completed_segments":1,"total_segments":1}"#
        XCTAssertNil(try CompanionClient.decoder.decode(AnalysisJob.self, from: Data(base.utf8)).warnings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
        json["warnings"] = ["Only paired double-quoted dialogue was analyzed."]
        let result = try CompanionClient.decoder.decode(AnalysisJob.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(result.warnings, ["Only paired double-quoted dialogue was analyzed."])
    }
    func testContractFixtureDecodesAndUsesScalarOffsets() throws {
        struct Fixture: Decodable { var book: RemoteBook; var job: RemoteJob }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "contract-v1", withExtension: "json"))
        let fixture = try CompanionClient.decoder.decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.book.sourceSha256.count, 64)
        XCTAssertEqual(fixture.job.status, "completed")
        let segment = try XCTUnwrap(fixture.book.segments.first)
        XCTAssertEqual(segment.locator.locator?.href.string, "EPUB/chapter1.xhtml")
        XCTAssertEqual(segment.locator.locator?.text.highlight, segment.text)
        let timing = try XCTUnwrap(fixture.job.assets.first?.timings.first)
        XCTAssertNotNil(SourceIdentity.scalarRange(timing.startOffset, timing.endOffset, in: segment.text))
    }
    func testCompanionRejectsInsecureAndCredentialURLs() throws {
        XCTAssertTrue(PinnedSessionDelegate.isLocalHost("192.168.1.20"))
        XCTAssertTrue(PinnedSessionDelegate.isLocalHost("100.100.1.2"))
        XCTAssertFalse(PinnedSessionDelegate.isLocalHost("8.8.8.8"))
        XCTAssertFalse(PinnedSessionDelegate.isLocalHost("example.com"))
        for url in ["http://example.com", "https://user:secret@example.com", "https://example.com?token=secret"] {
            XCTAssertThrowsError(try CompanionClient(url: URL(string: url)!, fingerprint: nil))
        }
        XCTAssertThrowsError(try CompanionClient(url: URL(string: "https://example.com")!, fingerprint: "wrong"))
        let client = try CompanionClient(url: URL(string: "https://example.com:8783")!, fingerprint: String(repeating: "a", count: 64), token: "test-only")
        XCTAssertThrowsError(try client.request("https://another.example/v1/assets/1"))
        XCTAssertThrowsError(try client.request("/v1/../../stolen"))
        let request = try client.request("/v1/assets/1")
        XCTAssertEqual(request.url?.host, "example.com")
        XCTAssertEqual(request.url?.port, 8783)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
    }
    func testGenerationPreservesSpanAndSnakeCase() throws {
        let request = GenerationRequest(requestId: "stable-request", bookId: "book", segmentIds: ["segment"], engine: "qwen3", voiceId: "narrator", language: "en", pronunciationRules: [], announceChapters: false, cast: nil, narrationPlan: [.init(segmentId: "segment", startOffset: 10, endOffset: 11, voiceId: "character")])
        let data = try CompanionClient.encoder.encode(request)
        let decoded = try CompanionClient.decoder.decode(GenerationRequest.self, from: data)
        XCTAssertEqual(decoded.requestId, "stable-request")
        XCTAssertEqual(decoded.narrationPlan?.first?.endOffset, 11)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["narration_plan"])
        XCTAssertNil(json["narrationPlan"])
    }

    @MainActor func testUncertainNewTakeSubmissionSurvivesRestartWithoutDuplicate() async throws {
        struct Fixture: Decodable { var book: RemoteBook }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "contract-v1", withExtension: "json"))
        let book = try CompanionClient.decoder.decode(Fixture.self, from: Data(contentsOf: url)).book
        let voice = try CompanionClient.decoder.decode(RemoteVoice.self, from: Data(#"{"id":"voice-test","name":"Test","engine":"kokoro","kind":"preset","language":"en"}"#.utf8))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let takeID = UUID().uuidString.lowercased()
        let first = CompanionStore(root: folder)
        do {
            try await first.generate(book: book, segments: book.segments.map(\.id), voice: voice, rules: [], announce: false, takeID: takeID)
            XCTFail("Submission without a companion must remain pending")
        } catch {}
        let original = try XCTUnwrap(first.pendingRequests.first)
        let restarted = CompanionStore(root: folder)
        XCTAssertEqual(restarted.pendingRequests.first?.takeId, takeID)
        do { try await restarted.generate(book: book, segments: book.segments.map(\.id), voice: voice, rules: [], announce: false, takeID: takeID) } catch {}
        XCTAssertEqual(restarted.pendingRequests.count, 1)
        XCTAssertEqual(restarted.pendingRequests.first?.requestId, original.requestId)
        do { try await restarted.generate(book: book, segments: book.segments.map(\.id), voice: voice, rules: [], announce: false, takeID: UUID().uuidString.lowercased()) } catch {}
        XCTAssertEqual(restarted.pendingRequests.count, 2, "A deliberate new take must keep its own identity")
    }
}
