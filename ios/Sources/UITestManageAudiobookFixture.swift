#if DEBUG
import Foundation

/// Explicit, authenticated simulated transport. Progress is a scripted server
/// job, not model inference or synthesized audio. The durable state belongs to
/// one isolated UI-test session and survives an actual app process restart.
enum UITestManageAudiobookFixture {
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--uitesting") && args.contains("--manage-audiobook-fixture")
    }
    static let title = "The Lantern — Manage transport fixture"
    static func configure(_ configuration: URLSessionConfiguration) { configuration.protocolClasses = [ManageAudiobookUITestProtocol.self] }
    @MainActor static func store(root: URL) throws -> CompanionStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ManageAudiobookUITestProtocol.stateURL = root.appendingPathComponent("manage-transport.json")
        let identity = CompanionIdentity(url: URL(string: "https://manage-audiobook.invalid")!, fingerprint: nil, deviceID: "test-only-manage-device")
        let configuration = URLSessionConfiguration.ephemeral; configure(configuration)
        let client = try CompanionClient(url: identity.url, fingerprint: nil, token: "test-only-manage-token", configuration: configuration)
        let store = CompanionStore(root: root, client: client); store.identity = identity
        try LibraryDatabase(url: root.appendingPathComponent("companion.sqlite")).write("identity", value: identity)
        return store
    }
    @MainActor static func install(library: LibraryStore, companion: CompanionStore) async throws {
        guard let source = Bundle.main.url(forResource: "lantern", withExtension: "epub") else { throw BookError.message("Original public Manage fixture is missing.") }
        var local = try await library.importBook(source); local.title = title; local.companionBookID = "manage-book"; library.update(local)
        let texts = [
            ["The Lantern", "Mira opened the brass lantern. A small blue light filled the room.", "“Can you hear me?” she asked. The answer arrived with a chime: “Yes, Mira.”", "A compass 🧭 pointed north; café bells sounded beyond the window."],
            ["Across the Bridge", "At dawn, Mira crossed the bridge. Below her, the river carried leaves toward the sea.", "“We have time,” said Rowan. “Then let us walk,” Mira replied.", "The lantern dimmed, but its light never disappeared."]
        ]
        let chapters = texts.enumerated().map { index, passages in
            RemoteChapter(id: "manage-chapter-\(index)", title: passages[0], href: "EPUB/chapter\(index + 1).xhtml", segments: passages.enumerated().map { offset, text in
                RemoteSegment(id: "manage-source-\(index)-\(offset)", text: text, kind: offset == 0 ? "heading" : "paragraph", locator: .object(["href": .string("EPUB/chapter\(index + 1).xhtml"), "type": .string("application/xhtml+xml"), "text": .object(["highlight": .string(text)])]))
            })
        }
        let book = RemoteBook(id: "manage-book", title: title, author: "Original public transport fixture", language: "en", sourceSha256: local.sourceSHA256, chapters: chapters)
        let data = try CompanionClient.encoder.encode(book)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BookError.message("Manage fixture encoding failed.") }
        try ManageAudiobookUITestProtocol.install(book: object)
        await companion.refresh()
    }
}

private final class ManageAudiobookUITestProtocol: URLProtocol {
    static var stateURL: URL?
    private static let lock = NSLock()
    static func install(book: [String: Any]) throws {
        try lock.withLock {
            guard let stateURL else { throw BookError.message("Manage fixture storage is missing.") }
            // Chapter two is already reviewed with an available narrator. It
            // deliberately must not inherit chapter one's unfinished analysis.
            let chapters = book["chapters"] as! [[String: Any]]
            let second = chapters[1]["segments"] as! [[String: Any]]
            let assignments = second.map { segment in ["id": "saved-" + (segment["id"] as! String), "segment_id": segment["id"]!, "start_offset": 0, "end_offset": (segment["text"] as! String).unicodeScalars.count, "character_id": "narrator", "confidence": 1.0, "reviewed": true] as [String: Any] }
            let state: [String: Any] = ["book": book, "revision": 0, "polls": 0, "jobs": [], "analysis_requests": [], "cast": ["characters": [["id": "narrator", "name": "Narrator", "aliases": [], "voice_id": "manage-kyon"]], "assignments": assignments]]
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { UITestManageAudiobookFixture.enabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        do {
            let result = try Self.lock.withLock { try reply(url) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: result.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result.1, options: [.sortedKeys]))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func reply(_ url: URL) throws -> (Int, [String: Any]) {
        guard url.host == "manage-audiobook.invalid", url.path == "/v1/health" || request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-manage-token" else { return (401, ["detail": "Explicit Manage fixture rejected this device."]) }
        if url.path == "/v1/health" { return (200, ["api_version": "1", "capabilities": ["source_ranges", "source_ranges_cast", "chapter_analysis", "analysis_request_id", "casting_review", "pronunciation_settings", "analysis_progress"]]) }
        if url.path == "/v1/voices" { return (200, ["voices": [["id": "manage-kyon", "name": "Kyon", "engine": "omnivoice", "kind": "preset", "language": "en"]]]) }
        if url.path == "/v1/engines" { return (200, ["engines": [["id": "omnivoice", "name": "Explicit Manage transport fixture", "available": true, "supports_cloning": false, "languages": ["en"], "license": "test-only transport; no synthesis"]]]) }
        if url.path == "/v1/pronunciations" { return (200, ["pronunciation_rules": [], "revision": 0]) }
        if url.path == "/v1/legacy-recordings" { return (200, ["recordings": []]) }
        guard let stateURL = Self.stateURL, let data = try? Data(contentsOf: stateURL), var state = try JSONSerialization.jsonObject(with: data) as? [String: Any], let book = state["book"] as? [String: Any] else { return (503, ["detail": "Manage transport fixture is installing."]) }
        if url.path == "/v1/books" { return (200, ["books": [book]]) }
        if url.path == "/v1/books/manage-book" { return (200, book) }
        if url.path.hasSuffix("/cast") {
            if request.httpMethod == "PUT" { state["cast"] = try body(); try persist(state, stateURL) }
            return (200, state["cast"] as! [String: Any])
        }
        if url.path.hasSuffix("/analyze") {
            let payload = try body()
            guard request.httpMethod == "POST", payload["allow_hosted"] as? Bool == true, payload["chapter_ids"] as? [String] == ["manage-chapter-0"], UUID(uuidString: payload["request_id"] as? String ?? "") != nil else { return (422, ["detail": "Manage analysis requires explicit hosted consent for only the selected chapter."]) }
            let requests = state["analysis_requests"] as? [[String: Any]] ?? []
            if let original = requests.first {
                guard NSDictionary(dictionary: original).isEqual(to: payload) else { return (409, ["detail": "The accepted analysis request must be recovered without a new identity or consent."]) }
                return (202, state["analysis"] as! [String: Any])
            }
            state["analysis_requests"] = [payload]; state["analysis"] = analysis(polls: 0)
            try persist(state, stateURL)
            if ProcessInfo.processInfo.arguments.contains("--manage-analysis-lost-response") { throw URLError(.timedOut) }
            return (202, state["analysis"] as! [String: Any])
        }
        if url.path == "/v1/analyses/manage-analysis" {
            guard state["analysis"] != nil else { return (404, ["detail": "No accepted analysis exists."]) }
            let polls = (state["polls"] as? Int ?? 0) + 1; state["polls"] = polls
            let updated = analysis(polls: polls); state["analysis"] = updated
            if updated["status"] as? String == "completed" { applySuggestions(&state, book: book) }
            try persist(state, stateURL); return (200, updated)
        }
        if url.path.hasSuffix("/analysis-status") {
            let job = state["analysis"] as? [String: Any]
            var first: [String: Any] = ["chapter_id": "manage-chapter-0", "status": job?["status"] ?? "not_analyzed"]
            if job != nil { first["analysis_id"] = "manage-analysis" }
            return (200, ["chapters": [first, ["chapter_id": "manage-chapter-1", "status": "completed", "pending_review_count": 0, "review_required": false]]])
        }
        if url.path.hasSuffix("/review-issues") {
            let selected = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "chapter_id" }?.value
            let completed = (state["analysis"] as? [String: Any])?["status"] as? String == "completed"
            let source = ((book["chapters"] as! [[String: Any]])[0]["segments"] as! [[String: Any]])[2]["text"] as! String
            let issue: [String: Any] = ["id": "manage-review-line", "chapter_id": "manage-chapter-0", "segment_id": "manage-source-0-2", "start_offset": 0, "end_offset": source.unicodeScalars.count, "source_text": source, "reason": "unreviewed_assignment", "message": "Review this exact speaker suggestion.", "status": "pending", "suggested_character_id": "mira"]
            return (200, ["book_id": "manage-book", "source_sha256": book["source_sha256"]!, "revision": state["revision"] ?? 0, "issues": completed && selected != "manage-chapter-1" ? [issue] : []])
        }
        if url.path == "/v1/jobs", request.httpMethod == "POST" {
            let payload = try body(), mode = payload["narration_mode"] as? String
            let ids = payload["segment_ids"] as? [String] ?? []
            let chapters = book["chapters"] as! [[String: Any]]
            let originalSegments = chapters.flatMap { $0["segments"] as! [[String: Any]] }
            let sourceRanges = payload["source_ranges"] as? [[String: Any]] ?? []
            guard payload["book_id"] as? String == "manage-book", payload["voice_id"] as? String == "manage-kyon", payload["engine"] as? String == "omnivoice",
                  !ids.isEmpty, Set(ids).count == ids.count, sourceRanges.count == ids.count,
                  sourceRanges.enumerated().allSatisfy({ index, range in
                      guard range["segment_id"] as? String == ids[index],
                            let original = originalSegments.first(where: { $0["id"] as? String == ids[index] }),
                            let start = range["start_offset"] as? Int, let end = range["end_offset"] as? Int else { return false }
                      return start >= 0 && start < end && end <= (original["text"] as! String).unicodeScalars.count
                  }) else { return (422, ["detail": "Generation selected different source bounds or an unavailable voice."]) }
            if mode == "full_cast" {
                let expected = (chapters[1]["segments"] as! [[String: Any]]).map { $0["id"] as! String }
                guard ids == expected, sourceRanges.allSatisfy({ $0["start_offset"] as? Int == 0 }) else { return (409, ["detail": "Selected chapter must use its exact canonical original ranges."]) }
            }
            if mode == "full_cast" && ids.contains(where: { $0.hasPrefix("manage-source-0-") }) { return (409, ["detail": "This chapter still needs its voice and speaker review."]) }
            var jobs = state["jobs"] as? [[String: Any]] ?? []
            var job = payload; job["id"] = "manage-generation-\(jobs.count + 1)"; job["status"] = "queued"; job["completed_segments"] = 0; job["total_segments"] = ids.count; job["assets"] = []; job["created_at"] = "2026-01-01T00:00:00Z"
            jobs.append(job); state["jobs"] = jobs; try persist(state, stateURL); return (202, job)
        }
        if url.path == "/v1/jobs" { return (200, ["jobs": state["jobs"] ?? []]) }
        if url.path.hasPrefix("/v1/jobs/manage-generation-"), let job = (state["jobs"] as? [[String: Any]])?.first(where: { $0["id"] as? String == url.lastPathComponent }) { return (200, job) }
        return (404, ["detail": "Unexpected explicit Manage transport route: " + url.path])
    }
    private func analysis(polls: Int) -> [String: Any] {
        let completed = polls >= 13
        return ["id": "manage-analysis", "book_id": "manage-book", "status": completed ? "completed" : "running", "completed_segments": polls < 3 ? 0 : polls < 11 ? 2 : 4, "total_segments": 4, "chapter_ids": ["manage-chapter-0"], "stage": completed ? "completed" : polls < 3 ? "reading" : polls < 11 ? "analyzing" : "saving", "current_chapter_id": "manage-chapter-0", "current_chapter_title": "The Lantern", "current_chapter_index": 1, "total_chapters": 1, "completed_batches": polls < 3 ? 0 : 1, "total_batches": 2]
    }
    private func applySuggestions(_ state: inout [String: Any], book: [String: Any]) {
        guard var cast = state["cast"] as? [String: Any] else { return }
        var characters = cast["characters"] as! [[String: Any]]
        if !characters.contains(where: { $0["id"] as? String == "mira" }) { characters.append(["id": "mira", "name": "Mira", "aliases": []]); cast["characters"] = characters }
        var assignments = cast["assignments"] as! [[String: Any]]
        if !assignments.contains(where: { $0["id"] as? String == "manage-suggestion" }) {
            let text = ((book["chapters"] as! [[String: Any]])[0]["segments"] as! [[String: Any]])[2]["text"] as! String
            assignments.append(["id": "manage-suggestion", "segment_id": "manage-source-0-2", "start_offset": 0, "end_offset": text.unicodeScalars.count, "character_id": "mira", "confidence": 0.75, "reviewed": false]); cast["assignments"] = assignments; state["revision"] = 1
        }
        state["cast"] = cast
    }
    private func body() throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    private func persist(_ state: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic) }
    override func stopLoading() {}
}
#endif
