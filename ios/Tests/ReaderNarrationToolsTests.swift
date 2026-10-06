import XCTest
import AVFoundation
import ReadiumShared
@testable import BookPocketOpen

private final class ReaderToolsProtocol: Foundation.URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var normalized = request
            if normalized.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&bytes, maxLength: 4096)
                    if count == 0 { break }
                    guard count > 0 else { throw URLError(.cannotDecodeContentData) }
                    body.append(contentsOf: bytes.prefix(count))
                }
                normalized.httpBody = body
            }
            let (status, data) = try Self.handler!(normalized)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ReaderNarrationToolsTests: XCTestCase {
    @MainActor func testTrimmedReferenceCreationReturnsVoiceForExistingCharacterDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); ReaderToolsProtocol.handler = nil }
        let rate = 8_000, count = rate * 8
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for sample in 0..<count { word(Int16(sin(2 * .pi * 220 * Double(sample) / Double(rate)) * 200)) }
        let original = folder.appendingPathComponent("explicit-reference-tone.wav"); try data.write(to: original)
        let editor = VoiceSampleEditor(); defer { editor.cleanUp() }; try editor.load(original)
        editor.start = 2; editor.end = 5; try editor.preview(); XCTAssertTrue(editor.playing); editor.stop()
        let trimmed = try await editor.export(); defer { try? FileManager.default.removeItem(at: trimmed) }
        XCTAssertEqual(try AVAudioPlayer(contentsOf: trimmed).duration, 3, accuracy: 0.05)
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"), client: try client())
        let created = RemoteVoice(id: "created-mira", name: "Mira", engine: "omnivoice", kind: "clone", language: "en")
        ReaderToolsProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/v1/voices"); XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Exact selected reference transcript"))
            return (201, try CompanionClient.encoder.encode(created))
        }
        let voice = try await store.clone(name: "Mira", engine: "omnivoice", language: "en", transcript: "Exact selected reference transcript", sample: trimmed)
        var cast = BookCast(characters: [.init(id: "mira", name: "Mira", aliases: ["Captain"], voiceId: nil)])
        cast.characters[0].voiceId = voice.id
        XCTAssertEqual(cast.characters[0].aliases, ["Captain"]); XCTAssertEqual(cast.characters[0].voiceId, created.id)
        XCTAssertEqual(store.voices.first?.id, created.id); XCTAssertEqual(try Data(contentsOf: original), data, "Reference trimming never changes the original file")
    }
    @MainActor func testExactTrimmedListeningSessionRestoresPausedAndDismissedOffline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let local = try await library.importBook(XCTUnwrap(Bundle(for: Self.self).url(forResource: "lantern", withExtension: "epub")))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        var (book, job, segment) = words(); book.sourceSha256 = local.sourceSHA256
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        try data.write(to: store.root.appendingPathComponent("tone.wav"))
        job.assets[0].sha256 = SourceIdentity.hash(data); job.assets[0].bytes = data.count
        job.assets[0].sourceTimings = [.init(start: 0.1, end: 0.25, startOffset: 2, endOffset: 9)]
        var second = segment; second.id = "second"; book.chapters[0].segments.append(second)
        var secondAsset = job.assets[0]; secondAsset.id = "second"; secondAsset.segmentId = second.id
        secondAsset.sourceTimings = [.init(start: 0, end: 0.15, startOffset: 0, endOffset: 9)]
        job.assets.append(secondAsset); job.segmentIds.append(second.id); job.completedSegments = 2; job.totalSegments = 2
        var newer = job; newer.id = "newest-unused-take"
        store.books = [book]; store.jobs = [newer, job]
        store.downloads = job.assets.enumerated().map { .init(localBookID: local.id, jobID: job.id, asset: $0.element, file: "tone.wav", segment: $0.offset == 0 ? segment : second) }
        try store.persistTransportFixture()
        let selection = DownloadedRecordingSelection(records: store.downloads, bounds: [(0.1, nil), (0, 0.15)])
        let player = PlaybackController(); defer { player.stop() }
        store.playRecording(selection, library: library, player: player, autoplay: false, scope: "Page")
        player.rate = 1.25; player.seek(0.2); player.dismissMiniPlayer()
        let reopened = CompanionStore(root: store.root), restored = PlaybackController(); defer { restored.stop() }
        await reopened.restoreListeningSession(library: LibraryStore(root: library.root), player: restored)
        XCTAssertNil(restored.error); XCTAssertFalse(restored.isPlaying); XCTAssertTrue(restored.miniPlayerDismissed)
        XCTAssertEqual(restored.recordingID, selection.id); XCTAssertEqual(restored.elapsed, 0.2, accuracy: 0.0001)
        XCTAssertEqual(restored.duration, 0.3, accuracy: 0.0001); XCTAssertEqual(restored.rate, 1.25)
        XCTAssertEqual(restored.listeningSession?.jobID, job.id); XCTAssertEqual(restored.listeningSession?.scope, "Page")
        XCTAssertEqual(restored.recordingPosition(at: restored.elapsed)?.index, 1)
        XCTAssertEqual(restored.recordingPosition(at: restored.elapsed)?.seconds ?? -1, 0.05, accuracy: 0.0001)
        restored.resume(); XCTAssertTrue(restored.isPlaying); XCTAssertFalse(restored.miniPlayerDismissed); restored.pause()
        try reopened.removeDownloadedTake(job.id)
        XCTAssertNil(CompanionStore(root: store.root).listeningSession, "Removing the selected download invalidates its resume state")
    }
    @MainActor func testMissingListeningDownloadNeverRestoresAnotherTake() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let local = try await library.importBook(XCTUnwrap(Bundle(for: Self.self).url(forResource: "lantern", withExtension: "epub")))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        let (_, job, segment) = words(); let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        var asset = job.assets[0]; asset.sha256 = SourceIdentity.hash(data); asset.bytes = data.count
        var valid = job; valid.assets = [asset]; store.jobs = [valid]
        let record = DownloadRecord(localBookID: local.id, jobID: job.id, asset: asset, file: "tone.wav", segment: segment)
        store.downloads = [record]; try data.write(to: store.root.appendingPathComponent(record.file)); try store.persistTransportFixture()
        let player = PlaybackController(); store.playRecording(.init(records: [record], bounds: [(0, nil)]), library: library, player: player, autoplay: false)
        player.seek(0.1); player.pause(); player.stop(); try FileManager.default.removeItem(at: store.root.appendingPathComponent(record.file))
        let restored = PlaybackController(); await CompanionStore(root: store.root).restoreListeningSession(library: library, player: restored)
        XCTAssertNil(restored.bookID); XCTAssertFalse(restored.isPlaying); XCTAssertNotNil(restored.error)
    }
    @MainActor func testGeneratedAuditionRecoversOriginalRequestWithoutBookQueuePollution() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); ReaderToolsProtocol.handler = nil }
        let store = CompanionStore(root: folder, client: try client())
        let request = VoicePreviewRequest(requestId: UUID().uuidString, voiceId: "mira", text: "Original audition", language: "en")
        ReaderToolsProtocol.handler = { incoming in
            if incoming.url!.path == "/v1/health" { return (200, Data("{\"capabilities\":[\"voice_previews\"]}".utf8)) }
            XCTAssertEqual(try CompanionClient.decoder.decode(VoicePreviewRequest.self, from: XCTUnwrap(incoming.httpBody)), request)
            throw URLError(.networkConnectionLost)
        }
        do { _ = try await store.voicePreview(request); XCTFail("Lost confirmation should retain its request") } catch {}
        let reopened = CompanionStore(root: folder, client: try client())
        XCTAssertEqual(reopened.voiceAuditions.first?.request, request)
        var accepted = VoicePreviewJob(id: "preview", voiceId: request.voiceId, status: "running")
        ReaderToolsProtocol.handler = { incoming in
            if incoming.url!.path == "/v1/health" { return (200, Data("{\"capabilities\":[\"voice_previews\"]}".utf8)) }
            if incoming.httpMethod == "POST" { XCTAssertEqual(try CompanionClient.decoder.decode(VoicePreviewRequest.self, from: XCTUnwrap(incoming.httpBody)), request); return (202, try CompanionClient.encoder.encode(accepted)) }
            XCTAssertEqual(incoming.url!.path, "/v1/voice-previews/preview")
            accepted.status = "completed"; accepted.asset = self.words().1.assets[0]
            return (200, try CompanionClient.encoder.encode(accepted))
        }
        let running = try await reopened.voicePreview(request)
        do { _ = try await reopened.voicePreviewAudio(running); XCTFail("Running auditions cannot be played as generated audio") } catch {}
        let completed = try await reopened.voicePreviewStatus(running.id)
        XCTAssertEqual(completed.status, "completed"); XCTAssertNotNil(completed.asset)
        XCTAssertTrue(reopened.jobs.isEmpty); XCTAssertTrue(reopened.books.isEmpty); XCTAssertTrue(reopened.downloads.isEmpty)
        XCTAssertEqual(CompanionStore(root: folder).voiceAuditions.first?.job?.status, "completed")
    }
    private func client() throws -> CompanionClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReaderToolsProtocol.self]
        return try CompanionClient(url: XCTUnwrap(URL(string: "https://reader-tools.invalid")), fingerprint: nil, token: "test-only", configuration: config)
    }
    private func words() -> (RemoteBook, RemoteJob, RemoteSegment) {
        let text = "A compass 🧭 pointed north; café bells sounded beyond the window."
        let source = RemoteSegment(id: "original", text: text, kind: "paragraph", locator: .object(["href": .string("EPUB/chapter1.xhtml"), "type": .string("application/xhtml+xml")]))
        let book = RemoteBook(id: "book", title: "Original source", author: "Test", language: "en", sourceSha256: String(repeating: "a", count: 64), chapters: [.init(id: "chapter", title: "Original", href: "EPUB/chapter1.xhtml", segments: [source])])
        let asset = AudioAsset(id: "asset", segmentId: source.id, mediaType: "audio/wav", duration: 0.25, sha256: "test", bytes: 1, url: "/v1/assets/asset", timings: [.init(start: 0, end: 0.25, startOffset: 0, endOffset: text.unicodeScalars.count)], alignment: "sentence")
        let job = RemoteJob(id: "take", bookId: book.id, status: "completed", engine: "omnivoice", voiceId: "test-only", segmentIds: [source.id], completedSegments: 1, totalSegments: 1, assets: [asset], narrationMode: "single", voiceName: "Kyon")
        return (book, job, source)
    }
    private func timing(_ word: String, text: String, start: Double, end: Double) throws -> AudioTiming {
        let range = try XCTUnwrap(text.range(of: word))
        return .init(start: start, end: end, startOffset: text[..<range.lowerBound].unicodeScalars.count, endOffset: text[..<range.upperBound].unicodeScalars.count)
    }
    func testWordHighlightUsesOriginalUnicodeSpansAndClearsSilenceWithoutGuessing() throws {
        let (_, job, segment) = words()
        var record = DownloadRecord(localBookID: "local", jobID: job.id, asset: job.assets[0], file: "tone.wav", segment: segment)
        record.asset.alignment = "word"
        record.asset.timings = [try timing("compass", text: segment.text, start: 0, end: 0.05), try timing("compass", text: segment.text, start: 0.05, end: 0.1), try timing("café", text: segment.text, start: 0.15, end: 0.25)]
        XCTAssertEqual(RecordedWordHighlight.locator(record: record, seconds: 0.01)?.text.highlight, "compass")
        XCTAssertEqual(RecordedWordHighlight.locator(record: record, seconds: 0.07)?.text.highlight, "compass", "Two spoken replacement words retain one original source span")
        XCTAssertNil(RecordedWordHighlight.locator(record: record, seconds: 0.12), "Silence must clear the word rather than stretching its duration")
        XCTAssertEqual(RecordedWordHighlight.locator(record: record, seconds: 0.2)?.text.highlight, "café", "Offsets after emoji are scalars, not UTF-16")
        XCTAssertNil(RecordedWordHighlight.locator(record: record, seconds: 0.25))
        record.asset.timings = []; XCTAssertNil(RecordedWordHighlight.locator(record: record, seconds: 0.1))
        record.asset.alignment = "sentence"
        XCTAssertEqual(RecordedWordHighlight.locator(record: record, seconds: 0.1)?.text.highlight, segment.text, "Legacy passage timing stays honest")
    }
    func testAppleSpokenUTF16RangeKeepsWordsAfterEmojiAndRejectsSplitSurrogates() throws {
        let text = "🧭 café bells"
        let range = try XCTUnwrap(text.range(of: "bells"))
        XCTAssertGreaterThan(NSRange(range, in: text).upperBound, text.count)
        let actual = try XCTUnwrap(SystemWordSpeechEngine.spokenRange(NSRange(range, in: text), in: text))
        XCTAssertEqual(String(text[actual]), "bells")
        XCTAssertNil(SystemWordSpeechEngine.spokenRange(NSRange(location: 1, length: 1), in: text))
        XCTAssertNil(SystemWordSpeechEngine.spokenRange(NSRange(location: 100, length: 1), in: text))
    }
    @MainActor func testAlignmentRepairPreservesActualJoinedAudioClockAndExactPageBounds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); ReaderToolsProtocol.handler = nil }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let local = try await library.importBook(XCTUnwrap(Bundle(for: Self.self).url(forResource: "lantern", withExtension: "epub")))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"), client: try client())
        var (book, job, segment) = words(); book.sourceSha256 = local.sourceSHA256
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        try data.write(to: store.root.appendingPathComponent("tone.wav"))
        job.assets[0].sha256 = SourceIdentity.hash(data); job.assets[0].bytes = data.count
        let boundary = try timing("café", text: segment.text, start: 0.15, end: 0.25)
        job.assets[0].timings = [boundary]
        var second = segment; second.id = "second"; book.chapters[0].segments.append(second)
        var secondAsset = job.assets[0]; secondAsset.id = "second-asset"; secondAsset.segmentId = second.id
        job.assets.append(secondAsset); job.segmentIds.append(second.id); job.completedSegments = 2; job.totalSegments = 2
        store.books = [book]; store.jobs = [job]
        store.downloads = zip(job.assets, [segment, second]).map { .init(localBookID: local.id, jobID: job.id, asset: $0.0, file: "tone.wav", segment: $0.1) }
        let page = ReaderSourceSelection(title: "Page", ranges: [.init(segmentId: segment.id, startOffset: boundary.startOffset, endOffset: boundary.endOffset)], excerpts: ["café"])
        let before = try DownloadedRecordingSelection.reader(job: job, selection: page, records: store.downloads)
        let player = PlaybackController(); defer { player.stop() }
        store.playRecording(.init(records: store.downloads, bounds: [(0, nil), (0, nil)]), library: library, player: player)
        player.pause(); player.seek(0.35)
        try await Task.sleep(for: .milliseconds(100))
        let duration = player.duration, elapsed = player.elapsed, recording = player.recordingID
        var repaired = job; repaired.alignmentStatus = "completed"
        for index in repaired.assets.indices {
            repaired.assets[index].sourceTimings = repaired.assets[index].timings
            repaired.assets[index].alignment = "word"
            repaired.assets[index].timings = [try timing("café", text: segment.text, start: 0.16, end: 0.24)]
        }
        try store.acceptAlignedMetadata(repaired)
        let after = try DownloadedRecordingSelection.reader(job: repaired, selection: page, records: store.downloads)
        XCTAssertEqual(before.id, after.id); XCTAssertEqual(after.duration, before.duration, accuracy: 0.0001)
        XCTAssertEqual(player.duration, duration, accuracy: 0.0001); XCTAssertEqual(player.elapsed, elapsed, accuracy: 0.0001)
        XCTAssertEqual(player.recordingID, recording); XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.recordingPosition(at: 0.35)?.index, 1)
        player.seek(0.45); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.speechLocator?.text.highlight, "café", "The active composition reads repaired metadata without restarting its item")
        XCTAssertEqual(SourceIdentity.hash(try Data(contentsOf: store.root.appendingPathComponent("tone.wav"))), job.assets[0].sha256)
        var malicious = repaired; malicious.assets[0].sourceTimings = nil
        XCTAssertThrowsError(try store.acceptAlignedMetadata(malicious), "Repair must retain known page-boundary evidence")
        malicious = repaired; malicious.assets[0].timings[0].endOffset = 10_000
        XCTAssertThrowsError(try store.acceptAlignedMetadata(malicious))
        var desktopRepair = repaired
        for index in desktopRepair.assets.indices { desktopRepair.assets[index].timings[0].start = 0.17 }
        ReaderToolsProtocol.handler = { request in
            let object: [String: Any]
            switch request.url!.path {
            case "/v1/engines": object = ["engines": []]
            case "/v1/voices": object = ["voices": []]
            case "/v1/legacy-recordings": object = ["recordings": []]
            case "/v1/pronunciations": object = ["pronunciation_rules": [], "revision": 0]
            case "/v1/jobs": return (200, try JSONSerialization.data(withJSONObject: ["jobs": [JSONSerialization.jsonObject(with: CompanionClient.encoder.encode(desktopRepair))]]))
            case "/v1/books": return (200, try JSONSerialization.data(withJSONObject: ["books": [JSONSerialization.jsonObject(with: CompanionClient.encoder.encode(book))]]))
            default: throw URLError(.unsupportedURL)
            }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.downloads[0].asset.timings[0].start, 0.17, accuracy: 0.0001, "Inventory refresh applies a desktop repair to the actual offline highlighting metadata")
        XCTAssertEqual(player.recordingID, recording); XCTAssertEqual(player.duration, duration, accuracy: 0.0001)
        XCTAssertEqual(player.elapsed, 0.45, accuracy: 0.001); XCTAssertFalse(player.isPlaying)
    }
    @MainActor func testPhoneCorrectionsPersistOfflineAndCASConflictKeepsDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); ReaderToolsProtocol.handler = nil }
        let store = CompanionStore(root: folder, client: try client())
        store.pronunciationRevision = 3
        let rules = [PronunciationRule(term: "Mira", replacement: "Mee rah"), PronunciationRule(term: "Rowan", replacement: "Roh un", enabled: false)]
        try store.savePronunciationsOnPhone(rules)
        let reopened = CompanionStore(root: folder)
        XCTAssertEqual(reopened.narrationPronunciations, rules); XCTAssertEqual(reopened.pronunciationDraftRevision, 3)
        var sawPUT = false
        ReaderToolsProtocol.handler = { request in
            if request.url!.path == "/v1/health" { return (200, Data("{\"capabilities\":[\"pronunciation_settings\"]}".utf8)) }
            XCTAssertEqual(request.httpMethod, "PUT"); sawPUT = true
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            XCTAssertEqual(body["expected_revision"] as? Int, 3)
            return (409, Data("{\"detail\":\"PC corrections changed\"}".utf8))
        }
        do { try await store.savePronunciationsToPC(); XCTFail("Stale revisions must not overwrite PC corrections") }
        catch let error as CompanionHTTPError { XCTAssertEqual(error.statusCode, 409) }
        XCTAssertTrue(sawPUT); XCTAssertEqual(store.narrationPronunciations, rules)
        XCTAssertEqual(CompanionStore(root: folder).narrationPronunciations, rules)
        let (book, job, segment) = words()
        let state = ReaderPlayerState(); state.mode = .kyon; state.remote = book
        state.selection = .init(title: "Exact page", ranges: [.init(segmentId: segment.id, startOffset: 0, endOffset: segment.text.unicodeScalars.count)], excerpts: [segment.text])
        state.voice = .init(id: job.voiceId, name: "Kyon", engine: job.engine, kind: "test-only", language: "en")
        let expectedRanges = state.selection?.ranges
        ReaderToolsProtocol.handler = { request in
            if request.url!.path == "/v1/health" { return (200, Data("{\"capabilities\":[\"source_ranges\",\"source_ranges_cast\"]}".utf8)) }
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url!.path, "/v1/jobs")
            let submitted = try CompanionClient.decoder.decode(GenerationRequest.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(submitted.pronunciationRules, rules)
            XCTAssertEqual(submitted.sourceRanges, expectedRanges)
            var accepted = job; accepted.status = "queued"; accepted.assets = []; accepted.completedSegments = 0; accepted.sourceRanges = submitted.sourceRanges
            return (202, try CompanionClient.encoder.encode(accepted))
        }
        await state.generate(companion: store)
        XCTAssertNil(state.error); XCTAssertEqual(state.selectedJobID, job.id)
        XCTAssertEqual(state.selection?.text, segment.text, "Generation submits corrections without altering the captured original")
        let original = "Mira greeted Rowan. Mirabelle waited. MIRA smiled."
        XCTAssertEqual(PronunciationCorrections.apply(rules, to: original), "Mee rah greeted Rowan. Mirabelle waited. Mee rah smiled.")
        XCTAssertEqual(original, "Mira greeted Rowan. Mirabelle waited. MIRA smiled.")
        try store.savePronunciationsOnPhone([])
        XCTAssertTrue(CompanionStore(root: folder).narrationPronunciations.isEmpty)
        XCTAssertThrowsError(try PronunciationCorrections.validate([.init(term: "Mira", replacement: "one"), .init(term: "mira", replacement: "two")]))
    }
    @MainActor func testConfirmedRemoteDeletionPreservesSharedFilesAndFailureKeepsPhoneCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); ReaderToolsProtocol.handler = nil }
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"), client: try client())
        let library = LibraryStore(root: folder.appendingPathComponent("Library")), player = PlaybackController()
        let (book, job, segment) = words(); var alternate = job; alternate.id = "alternate"
        store.books = [book]; store.jobs = [job, alternate]
        try Data([1]).write(to: store.root.appendingPathComponent("shared.wav"))
        store.downloads = [job, alternate].map { .init(localBookID: "local", jobID: $0.id, asset: job.assets[0], file: "shared.wav", segment: segment) }
        ReaderToolsProtocol.handler = { request in
            if request.url!.path == "/v1/health" { return (200, Data("{\"capabilities\":[\"delete_recordings\"]}".utf8)) }
            XCTAssertEqual(request.httpMethod, "DELETE"); return (503, Data("{\"detail\":\"Temporarily unavailable\"}".utf8))
        }
        do { try await store.deleteGeneratedTake(job.id, library: library, player: player); XCTFail("Failed deletion must preserve download") } catch {}
        XCTAssertEqual(store.downloads.count, 2); XCTAssertEqual(store.jobs.count, 2)
        ReaderToolsProtocol.handler = { request in
            if request.url!.path == "/v1/health" { return (200, Data("{\"capabilities\":[\"delete_recordings\"]}".utf8)) }
            XCTAssertEqual(request.httpMethod, "DELETE"); XCTAssertEqual(request.url!.path, "/v1/jobs/take"); return (204, Data())
        }
        try await store.deleteGeneratedTake(job.id, library: library, player: player)
        XCTAssertEqual(store.jobs.map(\.id), [alternate.id]); XCTAssertEqual(store.downloads.map(\.jobID), [alternate.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("shared.wav").path))
        XCTAssertThrowsError(try store.acceptAlignedMetadata(job), "A late alignment result cannot resurrect the deleted take")
        try store.removeDownloadedTake(alternate.id)
        XCTAssertEqual(store.jobs.map(\.id), [alternate.id], "Offline removal retains the PC recording metadata")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("shared.wav").path))
        XCTAssertTrue(CompanionStore(root: store.root).downloads.isEmpty)
    }
}
