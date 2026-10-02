import XCTest
@testable import BookPocketOpen

final class CompanionContractTests: XCTestCase {
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
}
