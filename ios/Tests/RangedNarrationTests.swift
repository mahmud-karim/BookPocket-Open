import XCTest
import ReadiumZIPFoundation
@testable import BookPocketOpen

private final class NarrationProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RangedNarrationTests: XCTestCase {
    private struct Fixture: Decodable {
        var book: RemoteBook
        var job: RemoteJob
        var partialAsset: AudioAsset
        var partialExpectedText: String
        var partialRequest: PartialRequest
        struct PartialRequest: Decodable { var sourceRanges: [SourceRange] }
    }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "contract-v1", withExtension: "json"))
        return try CompanionClient.decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func client() throws -> CompanionClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NarrationProtocol.self]
        return try CompanionClient(url: URL(string: "https://companion.example")!, fingerprint: nil, configuration: config)
    }
    func testWirePartialAssetKeepsAbsoluteScalarTimingsAndRejectsWidenedAudio() throws {
        let f = try fixture()
        var job = f.job; job.sourceRanges = f.partialRequest.sourceRanges; job.assets = [f.partialAsset]
        try RangedAudioValidation.validate(job: job, book: f.book)
        let range = try XCTUnwrap(SourceIdentity.scalarRange(f.partialAsset.sourceStart!, f.partialAsset.sourceEnd!, in: f.book.segments[0].text))
        XCTAssertEqual(String(f.book.segments[0].text[range]), f.partialExpectedText)
        XCTAssertEqual(job.assets[0].timings[0].startOffset, 10)
        job.assets[0].timings[0].startOffset = 0
        XCTAssertThrowsError(try RangedAudioValidation.validate(job: job, book: f.book))
        job.assets = [f.partialAsset]; job.assets[0].sourceEnd = f.book.segments[0].text.unicodeScalars.count
        XCTAssertThrowsError(try RangedAudioValidation.validate(job: job, book: f.book))
    }
    @MainActor func testCapabilityIsCheckedAtSubmitAndRetryAndDurableRequestsRetainRanges() async throws {
        let f = try fixture(); let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); NarrationProtocol.handler = nil }
        let voice = RemoteVoice(id: "fixture-kyon", name: "Kyon", engine: "voicestudio", kind: "clone", language: "en")
        let store = CompanionStore(root: folder, client: try client())
        var paths: [String] = []
        NarrationProtocol.handler = { request in
            paths.append(request.url!.path)
            return Data(#"{"version":"0.1.0"}"#.utf8)
        }
        do {
            try await store.generate(book: f.book, segments: f.job.segmentIds, voice: voice, rules: [], announce: false, sourceRanges: f.partialRequest.sourceRanges)
            XCTFail("An older PC must never receive a partial generation POST")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Update PC Companion")) }
        XCTAssertEqual(paths, ["/v1/health"])
        let pending = try XCTUnwrap(store.pendingRequests.first)
        let restarted = CompanionStore(root: folder, client: try client())
        XCTAssertEqual(restarted.pendingRequests.first?.sourceRanges, f.partialRequest.sourceRanges)
        var job = f.job; job.sourceRanges = f.partialRequest.sourceRanges; job.assets = []; job.status = "failed"
        let blockedRetry = await restarted.jobAction(job, "retry")
        XCTAssertFalse(blockedRetry)
        XCTAssertEqual(paths, ["/v1/health", "/v1/health"])
        var remote = job
        NarrationProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path == "/v1/health" { return Data(#"{"capabilities":["source_ranges"]}"#.utf8) }
            if request.url!.path.hasSuffix("/retry") || request.url!.path == "/v1/jobs" { remote.status = "queued" }
            return try CompanionClient.encoder.encode(remote)
        }
        let submitted = try await restarted.submit(pending)
        XCTAssertEqual(submitted.sourceRanges, f.partialRequest.sourceRanges)
        XCTAssertTrue(restarted.pendingRequests.isEmpty)
        let retried = await restarted.jobAction(job, "retry")
        XCTAssertTrue(retried)
        XCTAssertEqual(restarted.jobs.first?.status, "queued")
        remote.status = "completed"; remote.assets = [f.partialAsset]
        let completed = try await restarted.refreshJob(job.id)
        XCTAssertEqual(completed.status, "completed")
        XCTAssertEqual(CompanionStore(root: folder).jobs.first?.sourceRanges, f.partialRequest.sourceRanges)
        XCTAssertTrue(paths.suffix(3).elementsEqual(["/v1/health", "/v1/jobs/\(job.id)/retry", "/v1/jobs/\(job.id)"]))
    }
    @MainActor func testCachedPageAudioBelongsToEveryJobAndDeletionPreservesSharedFile() async throws {
        let f = try fixture(); let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); NarrationProtocol.handler = nil }
        let store = CompanionStore(root: folder, client: try client())
        let data = Data("Explicit cache bytes, not speech".utf8)
        var asset = f.partialAsset; asset.bytes = data.count; asset.sha256 = SourceIdentity.hash(data)
        var first = f.job; first.id = "first-page"; first.assets = [asset]; first.sourceRanges = f.partialRequest.sourceRanges
        var repeatPage = first; repeatPage.id = "repeat-page"
        var chapter = first; chapter.id = "overlapping-chapter"
        let local = LocalBook(id: "local-fixture", title: "Fixture", author: "Test", language: "en", sourceFile: "source.txt", readingFile: "source.epub", sourceSHA256: f.book.sourceSha256)
        let file = "Audio/" + SourceIdentity.hash(Data(asset.id.utf8)) + ".wav"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(file))
        store.books = [f.book]; store.jobs = [first, repeatPage, chapter]
        store.downloads = [.init(localBookID: local.id, jobID: first.id, asset: asset, file: file, segment: f.book.segments[0])]
        var requested = 0
        NarrationProtocol.handler = { _ in requested += 1; throw URLError(.notConnectedToInternet) }
        await store.download(repeatPage, localBook: local)
        await store.download(chapter, localBook: local)
        XCTAssertNil(store.error)
        XCTAssertEqual(requested, 0, "Verified cached assets must be reused")
        for job in [first, repeatPage, chapter] { XCTAssertEqual(store.orderedDownloads(jobID: job.id).map(\.asset.id), [asset.id]) }
        XCTAssertEqual(Set(store.downloads.map(\.id)).count, 3)
        let restarted = CompanionStore(root: folder, client: try client())
        XCTAssertEqual(restarted.orderedDownloads(jobID: repeatPage.id).count, 1)
        try restarted.removeDownloadedTake(first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
        // A retried job can replace an old segment artifact. The current manifest wins.
        var replacement = asset; replacement.id = "replacement"
        let replacementFile = "Audio/" + SourceIdentity.hash(Data(replacement.id.utf8)) + ".wav"
        try data.write(to: folder.appendingPathComponent(replacementFile))
        restarted.downloads.append(.init(localBookID: local.id, jobID: "seed", asset: replacement, file: replacementFile, segment: f.book.segments[0]))
        repeatPage.assets = [replacement]; restarted.jobs.removeAll { $0.id == repeatPage.id }; restarted.jobs.append(repeatPage)
        XCTAssertTrue(restarted.orderedDownloads(jobID: repeatPage.id).isEmpty, "Never play an obsolete segment asset after retry")
        await restarted.download(repeatPage, localBook: local)
        XCTAssertEqual(restarted.orderedDownloads(jobID: repeatPage.id).first?.asset.id, replacement.id)
        XCTAssertEqual(requested, 0)
        try restarted.removeDownloadedTake(chapter.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
        // Existing same-job files must be checksum-checked before being accepted.
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent(replacementFile))
        await restarted.download(repeatPage, localBook: local)
        XCTAssertEqual(requested, 1)
        XCTAssertNotNil(restarted.error)
    }
    @MainActor func testImportedPartialProjectRejectsOutOfSelectionTimingsBeforeImportingBook() async throws {
        let f = try fixture(); let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var job = f.job; job.sourceRanges = f.partialRequest.sourceRanges; job.assets = [f.partialAsset]
        job.assets[0].timings[0].endOffset += 1
        struct Project: Encodable { var formatVersion = 1; var book: RemoteBook; var job: RemoteJob }
        let manifest = folder.appendingPathComponent("project.json")
        try CompanionClient.encoder.encode(Project(book: f.book, job: job)).write(to: manifest)
        let zip = folder.appendingPathComponent("invalid.zip")
        let archive = try await Archive(url: zip, accessMode: .create)
        try await archive.addEntry(with: "project.json", fileURL: manifest)
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        do { try await store.importProject(zip, library: library); XCTFail("Invalid timings must not enter the library") }
        catch { XCTAssertTrue(error.localizedDescription.contains("selected source range")) }
        XCTAssertTrue(library.books.isEmpty); XCTAssertTrue(store.downloads.isEmpty)
    }
}
