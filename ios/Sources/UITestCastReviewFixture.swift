#if DEBUG
import Foundation

/// Authenticated, durable test transport for original-text cast review. It never
/// synthesizes audio or reports a production recording as ready.
enum UITestCastReviewFixture {
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--uitesting") && args.contains("--cast-review-fixture")
    }
    static let title = "Lantern review fixture"
    static let source = "🧭 Café bells rang. Mira said, “Keep the lantern steady."
    static let issueID = "original-unmatched-quote"
    static func configure(_ configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [CastReviewUITestProtocol.self]
    }
    @MainActor static func store(root: URL) throws -> CompanionStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CastReviewUITestProtocol.stateURL = root.appendingPathComponent("review-transport.json")
        let identity = CompanionIdentity(url: URL(string: "https://cast-review.invalid")!, fingerprint: nil, deviceID: "test-only-review-device")
        let configuration = URLSessionConfiguration.ephemeral
        configure(configuration)
        let client = try CompanionClient(url: identity.url, fingerprint: nil, token: "test-only-review-token", configuration: configuration)
        let store = CompanionStore(root: root, client: client)
        store.identity = identity
        try LibraryDatabase(url: root.appendingPathComponent("companion.sqlite")).write("identity", value: identity)
        return store
    }
    @MainActor static func install(library: LibraryStore, companion: CompanionStore) async throws {
        let sourceURL = companion.root.appendingPathComponent(title + ".txt")
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        var local = try await library.importBook(sourceURL)
        local.companionBookID = "cast-review-book"
        library.update(local)
        let texts = [title, source]
        let segments = texts.enumerated().map { index, text in
            RemoteSegment(id: "cast-review-source-\(index)", text: text, kind: index == 0 ? "heading" : "paragraph",
                locator: .object(["href": .string("text.xhtml"), "type": .string("application/xhtml+xml"), "text": .object(["highlight": .string(text)])]))
        }
        let book = RemoteBook(id: "cast-review-book", title: title, author: "Original public review fixture", language: "en", sourceSha256: local.sourceSHA256,
            chapters: [RemoteChapter(id: "cast-review-chapter", title: title, href: "text.xhtml", segments: segments)])
        let data = try CompanionClient.encoder.encode(book)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BookError.message("Review fixture book encoding failed.") }
        try CastReviewUITestProtocol.install(book: object)
        await companion.refresh()
    }
}

private final class CastReviewUITestProtocol: URLProtocol {
    static var stateURL: URL?
    private static let lock = NSLock()
    static func install(book: [String: Any]) throws {
        try lock.withLock {
            guard let stateURL else { throw BookError.message("Review fixture storage is missing.") }
            let state: [String: Any] = ["book": book, "revision": 0, "resolved": false, "resolve_attempts": 0, "jobs": [],
                "cast": ["characters": [["id": "narrator", "name": "Narrator", "aliases": [], "voice_id": "review-kyon"]], "assignments": []]]
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { UITestCastReviewFixture.enabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        do {
            let response = try Self.lock.withLock { try reply(url: url) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response.1, options: [.sortedKeys]))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func reply(url: URL) throws -> (Int, [String: Any]) {
        let health = url.path == "/v1/health"
        guard url.host == "cast-review.invalid", health || request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-review-token" else {
            return (401, ["detail": "Explicit review fixture rejected this device."])
        }
        if health { return (200, ["api_version": "1", "capabilities": ["source_ranges", "source_ranges_cast", "chapter_analysis", "analysis_request_id", "casting_review", "pronunciation_settings"]]) }
        let voices: [[String: Any]] = [["id": "review-kyon", "name": "Kyon", "engine": "omnivoice", "kind": "preset", "language": "en"],
            ["id": "review-mira", "name": "Mira review voice", "engine": "omnivoice", "kind": "preset", "language": "en"]]
        if url.path == "/v1/voices" { return (200, ["voices": voices]) }
        if url.path == "/v1/engines" { return (200, ["engines": [["id": "omnivoice", "name": "Explicit cast-review transport fixture", "available": true, "supports_cloning": false, "languages": ["en"], "license": "test-only transport; no synthesis"]]]) }
        if url.path == "/v1/pronunciations" { return (200, ["pronunciation_rules": [], "revision": 0]) }
        if url.path == "/v1/legacy-recordings" { return (200, ["recordings": []]) }
        guard let stateURL = Self.stateURL, let data = try? Data(contentsOf: stateURL), var state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let book = state["book"] as? [String: Any], let cast = state["cast"] as? [String: Any] else {
            return (503, ["detail": "Original review fixture is still installing."])
        }
        let revision = state["revision"] as? Int ?? 0
        let resolved = state["resolved"] as? Bool ?? false
        let scalars = Array(UITestCastReviewFixture.source.unicodeScalars)
        // The real scanner conservatively makes the whole ambiguous paragraph
        // reviewable, including prose which needs an explicit narrator choice.
        let start = 0
        var issue: [String: Any] = ["id": UITestCastReviewFixture.issueID, "chapter_id": "cast-review-chapter", "segment_id": "cast-review-source-1",
            "start_offset": start, "end_offset": scalars.count, "source_text": String(String.UnicodeScalarView(scalars[start...])),
            "reason": "ambiguous_quotation", "message": "This quotation is unfinished. Choose who reads the exact words.", "status": resolved ? "resolved" : "pending"]
        if url.path == "/v1/books" { return (200, ["books": [book]]) }
        if url.path == "/v1/books/cast-review-book" { return (200, book) }
        if url.path.hasSuffix("/cast") {
            guard request.httpMethod == "GET" else { return (409, ["detail": "Use the atomic review route for this issue."]) }
            return (200, cast)
        }
        if url.path.hasSuffix("/analysis-status") { return (200, ["chapters": [["chapter_id": "cast-review-chapter", "status": resolved ? "completed" : "failed", "pending_review_count": resolved ? 0 : 1, "manual_ready": resolved, "ready_for_generation": resolved]]]) }
        if url.path.hasSuffix("/review-issues") { return (200, ["book_id": "cast-review-book", "source_sha256": book["source_sha256"]!, "revision": revision, "issues": [issue]]) }
        if url.path.hasSuffix("/review-issues/" + UITestCastReviewFixture.issueID + "/resolve") {
            let body = try requestBody()
            let attempts = state["resolve_attempts"] as? Int ?? 0
            if ProcessInfo.processInfo.arguments.contains("--cast-review-conflict") && attempts == 0 {
                state["resolve_attempts"] = 1; state["revision"] = revision + 1
                try persist(state, at: stateURL)
                return (409, ["detail": "The cast changed on your PC. Your choices have been kept; refresh before saving."])
            }
            guard body["expected_revision"] as? Int == revision, UUID(uuidString: body["request_id"] as? String ?? "") != nil,
                  let character = body["character_id"] as? String, !character.isEmpty,
                  let voice = body["voice_id"] as? String, voices.contains(where: { $0["id"] as? String == voice }) else {
                return (409, ["detail": "Review must explicitly save a current speaker and available voice."])
            }
            var characters = cast["characters"] as? [[String: Any]] ?? []
            if !characters.contains(where: { $0["id"] as? String == character }) {
                guard let added = body["new_character"] as? [String: Any], added["id"] as? String == character else { return (422, ["detail": "Unknown review speaker."]) }
                characters.append(added)
            }
            for index in characters.indices where characters[index]["id"] as? String == character { characters[index]["voice_id"] = voice }
            let saved: [String: Any] = ["characters": characters, "assignments": [["id": "reviewed-original-quote", "segment_id": "cast-review-source-1", "start_offset": start, "end_offset": scalars.count, "character_id": character, "confidence": 1.0, "reviewed": true]]]
            state["cast"] = saved; state["revision"] = revision + 1; state["resolved"] = true
            try persist(state, at: stateURL)
            issue["status"] = "resolved"
            return (200, ["revision": revision + 1, "issue": issue, "cast": saved])
        }
        if url.path == "/v1/jobs", request.httpMethod == "POST" {
            let body = try requestBody()
            let rows = cast["assignments"] as? [[String: Any]] ?? []
            let plan = body["narration_plan"] as? [[String: Any]] ?? []
            let speaker = rows.first?["character_id"] as? String
            let character = (cast["characters"] as? [[String: Any]])?.first { $0["id"] as? String == speaker }
            guard resolved, body["narration_mode"] as? String == "full_cast", body["book_id"] as? String == "cast-review-book",
                  plan.contains(where: { ($0["segment_id"] as? String) == "cast-review-source-1" && ($0["start_offset"] as? Int) == start && ($0["end_offset"] as? Int) == scalars.count && ($0["voice_id"] as? String) == (character?["voice_id"] as? String) }) else {
                return (409, ["detail": "Exact original dialogue has not been explicitly reviewed with its selected voice."])
            }
            var job = body; job["id"] = "cast-review-generated"; job["status"] = "queued"; job["completed_segments"] = 0
            job["total_segments"] = (body["segment_ids"] as? [String])?.count ?? 0
            job["assets"] = []; job["created_at"] = "2026-01-01T00:00:00Z"
            state["jobs"] = [job]; try persist(state, at: stateURL)
            return (202, job)
        }
        if url.path == "/v1/jobs" { return (200, ["jobs": state["jobs"] ?? []]) }
        if url.path == "/v1/jobs/cast-review-generated", let job = (state["jobs"] as? [[String: Any]])?.first { return (200, job) }
        return (404, ["detail": "Unexpected explicit review transport route: " + url.path])
    }
    private func requestBody() throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    private func persist(_ state: [String: Any], at url: URL) throws { try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic) }
    override func stopLoading() {}
}
#endif
