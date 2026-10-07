import XCTest
import ReadiumShared
@testable import BookPocketOpen

private final class ReaderJobProtocol: Foundation.URLProtocol {
    static var handler: ((URLRequest, Data) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: 4096)
                    if count == 0 { break }
                    guard count > 0 else { throw URLError(.cannotDecodeContentData) }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let data = try Self.handler!(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class ReaderDownloadGate {
    let started = XCTestExpectation(description: "Download is awaiting completion")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func complete() { continuation?.resume(); continuation = nil }
}

final class ReaderPlayerTests: XCTestCase {
    @MainActor func testExactSourceDiscoveryRecoversCaptureAttentionWithoutHidingProductionErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var remote = book
        let other = RemoteSegment(id: "bridge", text: "At dawn, Mira crossed the bridge.", kind: "paragraph", locator: .object([:]))
        remote.chapters.append(.init(id: "bridge-chapter", title: "Across the Bridge", href: "bridge.xhtml", segments: [other]))
        let store = CompanionStore(root: root); store.books = [remote]
        var cast = job("bridge-cast"); cast.segmentIds = [other.id]; cast.narrationMode = "full_cast"
        store.jobs = [job(), cast]
        let local = LocalBook(id: "local", title: remote.title, author: remote.author, language: "en", sourceFile: "unused.txt", readingFile: "unused.txt", sourceSHA256: remote.sourceSha256)
        let state = store.readerPlayer(for: local.id); state.mode = .kyon; state.selectedJobID = "take"
        state.captureError = "No stable visible text was found. Stop scrolling and try again on a text page."
        XCTAssertNotNil(state.attention)
        let snapshot = ReaderScopeSnapshot(scope: .page, hrefs: ["text.xhtml", "bridge.xhtml"], documents: ["bridge.xhtml": .init(blocks: [.init(text: other.text, visible: [.init(start: 0, end: other.text.unicodeScalars.count)])], anchors: [])], current: .init(resource: 1, block: 0, offset: 0), boundaries: [], isText: false)
        // A successful capture must recover the transient navigation error,
        // while preserving exact chapter and narrator isolation.
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertEqual(state.selection?.ranges.map(\.segmentId), [other.id])
        XCTAssertEqual(state.selection?.text, other.text)
        XCTAssertNil(state.attention); XCTAssertNil(state.selectedJobID)
        XCTAssertTrue(state.candidates.isEmpty); XCTAssertTrue(state.readyIDs.isEmpty)
        state.error = "Generation failed. Retry this job."
        state.captureError = "The previous page stopped responding."
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertNil(state.captureError)
        XCTAssertEqual(state.attention, "Generation failed. Retry this job.", "Source recovery cannot hide a genuine production failure")
        state.captureError = "An exact source capture is still required."
        var invalid = snapshot; invalid.documents = [:]
        state.discover(snapshot: invalid, local: local, companion: store)
        XCTAssertEqual(state.captureError, "An exact source capture is still required.", "An unmappable source cannot claim recovery")
        XCTAssertNil(state.selection); XCTAssertNil(state.selectedJobID); XCTAssertTrue(state.readyIDs.isEmpty)
        state.captureError = nil
        state.discover(snapshot: invalid, local: local, companion: store)
        XCTAssertNotNil(state.captureError, "A newly unmappable source must report its real error rather than appear as ungenerated audio")
        XCTAssertEqual(state.attention, "Generation failed. Retry this job.", "A source failure cannot discard an existing production failure")
    }
    @MainActor func testReaderCaptureDeadlineReleasesStalledCaptureAndIgnoresLateResults() async throws {
        let stalled = ReaderDownloadGate()
        var busy = false, lateReturned = false
        let expired = Task { @MainActor in
            busy = true; defer { busy = false }
            return try await ReaderCaptureDeadline.evaluate(timeout: .milliseconds(150)) {
                await stalled.wait(); lateReturned = true; return "obsolete page"
            }
        }
        await fulfillment(of: [stalled.started], timeout: 2)
        do { _ = try await expired.value; XCTFail("A missing web-view callback must fail safely, not lock source capture") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reader page stopped responding")) }
        XCTAssertFalse(busy, "The owner must unwind its capture lock when the callback stalls")
        let fresh = try await ReaderCaptureDeadline.evaluate { "new page" }
        stalled.complete(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(lateReturned, "The actual old callback was delivered after timeout")
        XCTAssertEqual(fresh, "new page", "A late old callback cannot replace the newer exact source result")
        let cancelled = ReaderDownloadGate()
        let capture = Task { @MainActor in
            try await ReaderCaptureDeadline.evaluate(timeout: .seconds(5)) { await cancelled.wait(); return "cancelled page" }
        }
        await fulfillment(of: [cancelled.started], timeout: 2)
        capture.cancel()
        do { _ = try await capture.value; XCTFail("Cancelled capture must immediately unlock its owner") }
        catch { XCTAssertTrue(error is CancellationError) }
        cancelled.complete()
    }
    @MainActor func testSavedAudioFromWiderTakeKeepsOnlyCurrentChapterAndRestoresScopedExcerpt() throws {
        var remote = book
        let other = RemoteSegment(id: "other-source", text: "Original words from the next chapter.", kind: "paragraph", locator: .object([:]))
        remote.chapters.append(.init(id: "other-chapter", title: "Next chapter", href: "other.xhtml", segments: [other]))
        var whole = job("whole-book")
        whole.segmentIds = ["segment", other.id]; whole.completedSegments = 2; whole.totalSegments = 2
        whole.assets = remote.segments.enumerated().map { index, segment in
            .init(id: "asset-\(index)", segmentId: segment.id, mediaType: "audio/wav", duration: index == 0 ? 2 : 3, sha256: String(repeating: "a", count: 64), bytes: 100, url: "/explicit-test-only", timings: [], narrationMode: "single")
        }
        for (index, expected) in [(0, 2.0), (1, 3.0)] {
            let catalog = ReaderAudioCatalog.recordings(book: remote, chapter: remote.chapters[index], mode: .kyon, jobs: [whole], localBookID: "local", downloads: { _ in [] })
            let chosen = try XCTUnwrap(catalog.first)
            XCTAssertEqual(chosen.scope, .chapter)
            XCTAssertEqual(chosen.selection.ranges.map(\.segmentId), remote.chapters[index].segments.map(\.id), "A whole-book take must not turn a selected chapter into whole-book playback")
            XCTAssertEqual(chosen.duration, expected, accuracy: 0.001)
        }
        var excerpt = whole; excerpt.id = "cross-chapter-excerpt"
        excerpt.sourceRanges = [range, .init(segmentId: other.id, startOffset: 0, endOffset: 5)]
        for index in excerpt.assets.indices {
            excerpt.assets[index].sourceStart = excerpt.sourceRanges?[index].startOffset
            excerpt.assets[index].sourceEnd = excerpt.sourceRanges?[index].endOffset
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionStore(root: root); store.books = [remote]; store.jobs = [excerpt]
        let local = LocalBook(id: "local", title: remote.title, author: remote.author, language: "en", sourceFile: "unused.txt", readingFile: "unused.txt", sourceSHA256: remote.sourceSha256)
        let state = store.readerPlayer(for: local.id); state.mode = .kyon; state.savedJobID = excerpt.id
        let snapshot = ReaderScopeSnapshot(scope: .page, hrefs: ["text.xhtml"], documents: ["text.xhtml": .init(blocks: [.init(text: words, visible: [.init(start: 20, end: 24)])], anchors: [])], current: .init(resource: 0, block: 0, offset: 20), boundaries: [], isText: false)
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertEqual(state.savedJobID, excerpt.id)
        XCTAssertEqual(state.selection?.ranges.map(\.segmentId), ["segment"], "Restoring a saved cross-chapter excerpt preserves only its current chapter's exact spans")
        XCTAssertEqual(state.selection?.ranges.first?.startOffset, range.startOffset)
        XCTAssertEqual(state.selection?.ranges.first?.endOffset, range.endOffset)
    }
    private let words = "A compass 🧭 said, “Stay.” Then Mira replied, “Go.”"
    private var book: RemoteBook { .init(id: "original-book", title: "Original reader fixture", author: "Test", language: "en", sourceSha256: "original-sha", chapters: [.init(id: "chapter", title: "Original", href: "text.xhtml", segments: [.init(id: "segment", text: words, kind: "paragraph", locator: .object([:]))])]) }
    private var voice: RemoteVoice { .init(id: "fixture-kyon", name: "Kyon", engine: "voicestudio", kind: "test-only", language: "en") }
    private var engine: RemoteEngine { .init(id: "voicestudio", name: "Fixture only", available: true, supportsCloning: false, languages: ["en"], license: "Test") }
    private var range: SourceRange { .init(segmentId: "segment", startOffset: 10, endOffset: 20) }
    private var selection: ReaderSourceSelection { .init(title: "Page", ranges: [range], excerpts: ["🧭 said, “S"]) }
    private func job(_ id: String = "take") -> RemoteJob {
        .init(id: id, bookId: book.id, status: "completed", engine: voice.engine, voiceId: voice.id, segmentIds: ["segment"], completedSegments: 1, totalSegments: 1, assets: [], narrationMode: "single", voiceName: "Kyon")
    }
    @MainActor func testDelayedDownloadPreservesResultButCannotAutoplayAStaleReaderIntent() async throws {
        for change in ["unchanged", "take", "narrator", "selection", "snapshot", "position", "book", "dismissed", "away-and-back", "manual-pause"] {
            let state = ReaderPlayerState()
            state.mode = .kyon; state.selectedJobID = "take-A"; state.selection = selection
            var currentBook = "local"
            var location: Locator?
            let intent = state.playbackIntent(jobID: "take-A", bookID: currentBook, location: location)
            let gate = ReaderDownloadGate()
            var saved = false, played: [String] = []
            let operation = Task {
                await state.downloadWithIntent(intent, currentBookID: { currentBook }, currentLocation: { location }, download: {
                    await gate.wait(); saved = true; return true
                }, play: { played.append(intent.jobID) })
            }
            await fulfillment(of: [gate.started], timeout: 2)
            XCTAssertTrue(state.working)
            switch change {
            case "take": state.selectedJobID = "ready-take-B"
            case "narrator": state.mode = .cast
            case "selection": state.selection?.ranges[0].endOffset += 1
            case "snapshot": state.snapshot = .init(scope: .page, hrefs: ["text.xhtml"], documents: [:], current: .init(resource: 0, block: 0, offset: 10), boundaries: [], isText: false)
            case "position": location = try Locator(jsonString: #"{"href":"text.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5}}"#)
            case "book": currentBook = "another-book"
            case "dismissed", "manual-pause": state.invalidatePlaybackIntent()
            case "away-and-back": state.invalidatePlaybackIntent(); state.selectedJobID = "ready-take-B"; state.selectedJobID = "take-A"
            default: break
            }
            gate.complete()
            let result = await operation.value
            XCTAssertTrue(result && saved, "\(change): a completed download must remain available")
            XCTAssertFalse(state.working)
            XCTAssertEqual(played, change == "unchanged" ? ["take-A"] : [], "\(change): only the unchanged captured intent may start its own take")
        }
    }
    func testFullCastClipsReviewedUnicodeSpansWithoutChangingOriginalOffsets() throws {
        let cast = BookCast(characters: [.init(id: "narrator", name: "Narrator", aliases: [], voiceId: voice.id), .init(id: "mira", name: "Mira", aliases: [], voiceId: "mira-voice")], assignments: [
            .init(id: "crossing", segmentId: "segment", startOffset: 0, endOffset: 12, characterId: "mira", confidence: 1, reviewed: true),
            .init(id: "inside", segmentId: "segment", startOffset: 17, endOffset: 24, characterId: "mira", confidence: 1, reviewed: true),
            .init(id: "outside", segmentId: "segment", startOffset: 30, endOffset: 34, characterId: "mira", confidence: 0.2, reviewed: false)
        ])
        var other = voice; other.id = "mira-voice"
        let plan = try ReaderCastPlan.build(cast: cast, book: book, ranges: [range], voices: [voice, other], engines: [engine])
        XCTAssertEqual(plan.spans, [.init(segmentId: "segment", startOffset: 10, endOffset: 12, voiceId: other.id), .init(segmentId: "segment", startOffset: 17, endOffset: 20, voiceId: other.id)])
        XCTAssertEqual(String(words[try XCTUnwrap(SourceIdentity.scalarRange(10, 11, in: words))]), "🧭")
        XCTAssertEqual(plan.narrator.id, voice.id, "Unassigned gaps keep the explicitly saved narrator")
        var unreviewed = cast; unreviewed.assignments[1].reviewed = false
        XCTAssertThrowsError(try ReaderCastPlan.build(cast: unreviewed, book: book, ranges: [range], voices: [voice, other], engines: [engine]))
        var overlapping = cast; overlapping.assignments[1].startOffset = 11
        XCTAssertThrowsError(try ReaderCastPlan.build(cast: overlapping, book: book, ranges: [range], voices: [voice, other], engines: [engine]))
        var unavailable = engine; unavailable.available = false
        XCTAssertThrowsError(try ReaderCastPlan.build(cast: cast, book: book, ranges: [range], voices: [voice, other], engines: [unavailable]))
        let prose = try ReaderCastPlan.build(cast: .init(characters: [cast.characters[0]]), book: book, ranges: [range], voices: [voice], engines: [engine])
        XCTAssertTrue(prose.spans.isEmpty, "A full-cast prose-only page remains an explicitly marked full-cast request")
    }
    func testTakeMatchingRequiresNarratorProvenanceAndCoversCurrentPage() {
        let original = job()
        XCTAssertEqual(ReaderTakeMatch.mode(original), .kyon)
        var managed = original; managed.engine = "omnivoice"
        XCTAssertEqual(ReaderTakeMatch.mode(managed), .kyon)
        managed.voiceName = nil
        XCTAssertNil(ReaderTakeMatch.mode(managed), "An engine identity does not establish narrator provenance")
        managed.voiceName = "Kyon"; managed.narrationMode = "full_cast"
        XCTAssertEqual(ReaderTakeMatch.mode(managed), .cast, "A Kyon narrator does not turn a full cast take into a single voice take")
        XCTAssertTrue(ReaderTakeMatch.covers(original, book: book, selection: selection), "A chapter take covers a page within it")
        var excerpt = original; excerpt.sourceRanges = [range]
        XCTAssertTrue(ReaderTakeMatch.covers(excerpt, book: book, selection: selection))
        excerpt.sourceRanges?[0].endOffset = 19
        XCTAssertFalse(ReaderTakeMatch.covers(excerpt, book: book, selection: selection))
        excerpt.sourceRanges = [.init(segmentId: "segment", startOffset: 20, endOffset: 30)]
        XCTAssertFalse(ReaderTakeMatch.covers(excerpt, book: book, selection: selection))
        var foreign = original; foreign.bookId = "another-book"
        XCTAssertFalse(ReaderTakeMatch.covers(foreign, book: book, selection: selection))
        var unknown = original; unknown.voiceName = nil
        XCTAssertNil(ReaderTakeMatch.mode(unknown))
        unknown.voiceName = "Other voice"; XCTAssertNil(ReaderTakeMatch.mode(unknown))
        unknown.narrationMode = "full_cast"; unknown.narrationPlan = []
        XCTAssertEqual(ReaderTakeMatch.mode(unknown), .cast)
        unknown.narrationMode = nil; unknown.narrationPlan = [.init(segmentId: "segment", startOffset: 10, endOffset: 11, voiceId: voice.id)]
        XCTAssertEqual(ReaderTakeMatch.mode(unknown), .cast, "Legacy positive cast evidence remains usable")
    }
    @MainActor func testDiscoveryKeepsAlternateTakesExplicitAndExcludesDamagedOrForeignFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionStore(root: root)
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        try data.write(to: root.appendingPathComponent("tone.wav"))
        let local = LocalBook(id: "local", title: "Fixture", author: "Test", language: "en", sourceFile: "test.txt", readingFile: "test.epub", sourceSHA256: book.sourceSha256)
        let asset = AudioAsset(id: "shared-audio", segmentId: "segment", mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/test-only", timings: [], narrationMode: "single")
        var first = job(); first.assets = [asset]
        var alternate = first; alternate.id = "alternate"
        var foreign = first; foreign.id = "foreign"; foreign.bookId = "foreign-book"
        var wrongVoice = first; wrongVoice.id = "wrong-voice"; wrongVoice.voiceName = "Other narrator"
        store.books = [book]; store.jobs = [first, alternate, foreign, wrongVoice]
        store.downloads = store.jobs.map { .init(localBookID: local.id, jobID: $0.id, asset: asset, file: "tone.wav", segment: book.segments[0]) }
        let snapshot = ReaderScopeSnapshot(scope: .page, hrefs: ["text.xhtml"], documents: ["text.xhtml": .init(blocks: [.init(text: words, visible: [.init(start: 10, end: 20)])], anchors: [])], current: .init(resource: 0, block: 0, offset: 10), boundaries: [], isText: false)
        let state = store.readerPlayer(for: local.id); state.mode = .kyon
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertEqual(Set(state.candidates.map(\.id)), [first.id, alternate.id])
        XCTAssertEqual(state.readyIDs, [first.id, alternate.id]); XCTAssertNil(state.selectedJobID)
        XCTAssertTrue(state.requiresTakeSelection, "Existing matching audio requires a choice, not a missing-audio message")
        state.selectedJobID = alternate.id
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertEqual(state.selectedJobID, alternate.id)
        XCTAssertFalse(state.requiresTakeSelection)
        XCTAssertTrue(store.readerPlayer(for: local.id) === state, "Closing a panel retains its explicit take")
        XCTAssertFalse(store.readerPlayer(for: "another-local") === state)
        try Data([0]).write(to: root.appendingPathComponent("tone.wav"))
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertTrue(state.readyIDs.isEmpty, "Persisted metadata does not make damaged audio ready")
    }
    @MainActor func testSavedPageCatalogSurvivesReflowWithoutRequiringChapterAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionStore(root: root)
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        try data.write(to: root.appendingPathComponent("clip.wav"))
        let local = LocalBook(id: "local", title: "Fixture", author: "Test", language: "en", sourceFile: "test.txt", readingFile: "test.epub", sourceSHA256: book.sourceSha256)
        let asset = AudioAsset(id: "clip-audio", segmentId: "segment", mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/test-only", timings: [], sourceStart: 10, sourceEnd: 20, narrationMode: "single", castSpans: [])
        var clip = job("page-clip"); clip.sourceRanges = [range]; clip.assets = [asset]
        var onPC = clip; onPC.id = "remote-clip"
        var cast = clip; cast.id = "cast-clip"; cast.narrationMode = "full_cast"; cast.assets[0].narrationMode = "full_cast"
        var wrongSource = clip; wrongSource.id = "other-book"; wrongSource.bookId = "foreign"
        var malformed = clip; malformed.id = "unconfirmed-range"; malformed.assets[0].sourceEnd = 19
        store.books = [book]; store.jobs = [clip, onPC, cast, wrongSource, malformed]
        store.downloads = [.init(localBookID: local.id, jobID: clip.id, asset: asset, file: "clip.wav", segment: book.segments[0])]
        func catalog() -> [ReaderAudioRecording] {
            ReaderAudioCatalog.recordings(book: book, chapter: book.chapters[0], mode: .kyon, jobs: store.jobs,
                localBookID: local.id, downloads: store.orderedDownloads)
        }
        XCTAssertEqual(Set(catalog().map(\.id)), [clip.id, onPC.id])
        XCTAssertTrue(catalog().allSatisfy { $0.scope == .page }, "Two excerpts do not imply a complete chapter")
        XCTAssertEqual(catalog().first(where: { $0.id == clip.id })?.offline, true)
        XCTAssertEqual(catalog().first(where: { $0.id == onPC.id })?.offline, false)
        let state = store.readerPlayer(for: local.id); state.mode = .kyon
        var snapshot = ReaderScopeSnapshot(scope: .page, hrefs: ["text.xhtml"], documents: ["text.xhtml": .init(blocks: [.init(text: words, visible: [.init(start: 10, end: 20)])], anchors: [])], current: .init(resource: 0, block: 0, offset: 10), boundaries: [], isText: false)
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertEqual(state.candidates.count, 3, "Discovery can include malformed candidates but never mark them ready")
        state.savedJobID = clip.id; state.selectedJobID = clip.id
        snapshot.documents["text.xhtml"]?.blocks[0].visible = [.init(start: 20, end: 30)]
        snapshot.current.offset = 20
        state.discover(snapshot: snapshot, local: local, companion: store)
        XCTAssertEqual(state.selectedJobID, clip.id)
        XCTAssertEqual(state.selection?.ranges, [range], "Explicit saved playback keeps its original words after reflow")
        XCTAssertEqual(state.pageSelection?.ranges.first?.startOffset, 20)
        XCTAssertEqual(catalog().count, 2, "Clips remain browsable when they no longer cover the visible page")
        try Data([0]).write(to: root.appendingPathComponent("clip.wav"))
        XCTAssertEqual(catalog().first(where: { $0.id == clip.id })?.offline, false, "A damaged download remains discoverable on PC, but cannot play offline")
    }
    @MainActor func testFullCastRequestRecoveryRetainsExactRangesPlanAndModeAcrossStoreReconstruction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { ReaderJobProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ReaderJobProtocol.self]
        let client = try CompanionClient(url: URL(string: "https://reader-fixture.example")!, fingerprint: nil, configuration: configuration)
        let store = CompanionStore(root: root, client: client); store.books = [book]
        let state = store.readerPlayer(for: "local"); state.mode = .cast; state.remote = book; state.selection = selection; state.voice = voice
        state.plan = [.init(segmentId: "segment", startOffset: 10, endOffset: 11, voiceId: voice.id)]
        var capable = false, loseReply = true
        var received: [GenerationRequest] = []
        var reply = job("accepted-on-pc"); reply.status = "queued"; reply.narrationMode = "full_cast"; reply.sourceRanges = selection.ranges; reply.narrationPlan = state.plan
        var responseData = try CompanionClient.encoder.encode(reply)
        ReaderJobProtocol.handler = { request, body in
            if request.url!.path == "/v1/health" { return Data((capable ? #"{"capabilities":["source_ranges","source_ranges_cast"]}"# : #"{"capabilities":["source_ranges"]}"#).utf8) }
            received.append(try CompanionClient.decoder.decode(GenerationRequest.self, from: body))
            if loseReply { throw URLError(.networkConnectionLost) }
            return responseData
        }
        await state.generate(companion: store)
        XCTAssertTrue(received.isEmpty); XCTAssertTrue(state.error?.contains("Update PC Companion") == true)
        capable = true
        await state.generate(companion: store)
        XCTAssertEqual(received.count, 1); XCTAssertNil(state.selectedJobID)
        let pending = try XCTUnwrap(store.pendingRequests.first)
        XCTAssertEqual(pending.narrationMode, "full_cast"); XCTAssertEqual(pending.sourceRanges, selection.ranges)
        let restored = CompanionStore(root: root, client: client)
        loseReply = false
        let recovered = try await restored.submit(try XCTUnwrap(restored.pendingRequests.first))
        XCTAssertEqual(recovered.id, reply.id); XCTAssertEqual(received.map(\.requestId), [pending.requestId, pending.requestId])
        XCTAssertEqual(received.last?.narrationPlan, state.plan); XCTAssertTrue(restored.pendingRequests.isEmpty)
        XCTAssertEqual(restored.jobs.first?.narrationMode, "full_cast")
        // Studio's saved-cast selection can contain only narrator prose. Its
        // explicit mode must survive the real request despite having no plan.
        reply.id = "narrator-only-cast"; reply.sourceRanges = nil; reply.narrationPlan = []
        responseData = try CompanionClient.encoder.encode(reply)
        capable = false
        let beforeWholeRequest = received.count
        do {
            _ = try await restored.generate(book: book, segments: ["segment"], voice: voice, rules: [], announce: false, narrationMode: "full_cast")
            XCTFail("An old PC must be rejected before accepting whole-chapter work")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Update PC Companion")) }
        XCTAssertEqual(received.count, beforeWholeRequest, "Explicit whole-source mode also requires capability before POST")
        let resumed = await restored.jobAction(reply, "resume")
        XCTAssertFalse(resumed); XCTAssertEqual(received.count, beforeWholeRequest)
        capable = true
        let prose = try await restored.generate(book: book, segments: ["segment"], voice: voice, rules: [], announce: false, narrationMode: "full_cast")
        XCTAssertEqual(received.last?.narrationMode, "full_cast")
        XCTAssertNil(received.last?.narrationPlan); XCTAssertNil(received.last?.sourceRanges)
        XCTAssertEqual(ReaderTakeMatch.mode(prose), .cast)
    }
}
