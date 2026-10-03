import AVFoundation
import XCTest
@testable import BookPocketOpen

/// Exercises URLSession's real download path without a PC or a speech engine.
private final class InterruptedAudioProtocol: URLProtocol {
    enum Reply { case complete(Data), interrupted(Data) }
    static var handler: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            switch reply {
            case .complete(let data):
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .interrupted(let prefix):
                client?.urlProtocol(self, didLoad: prefix)
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DownloadRecoveryTests: XCTestCase {
    private func client() throws -> CompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedAudioProtocol.self]
        return try CompanionClient(url: URL(string: "https://download-fixture.example")!, fingerprint: nil, configuration: configuration)
    }
    @MainActor private func fixture(_ folder: URL) async throws -> (LibraryStore, LocalBook, RemoteBook, RemoteJob, Data) {
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let epub = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lantern", withExtension: "epub"))
        let local = try await library.importBook(epub)
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        let segments = (0..<3).map { RemoteSegment(id: "passage-\($0)", text: "Original transport fixture passage \($0).", kind: "paragraph", locator: .object([:])) }
        let remote = RemoteBook(id: "recovery-book", title: "Original transport test — not speech", author: "Test", language: "en", sourceSha256: local.sourceSHA256, chapters: [.init(id: "chapter", title: "Three passages", href: "test.xhtml", segments: segments)])
        let assets = segments.enumerated().map { index, segment in
            AudioAsset(id: "audio-\(index)", segmentId: segment.id, mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/v1/assets/audio-\(index)", timings: [])
        }
        let job = RemoteJob(id: "recovery-job", bookId: remote.id, status: "completed", engine: "test-only-pcm", voiceId: "not-a-voice", segmentIds: segments.map(\.id), completedSegments: 3, totalSegments: 3, assets: assets)
        return (library, local, remote, job, data)
    }
    private func file(_ asset: AudioAsset) -> String { "Audio/" + SourceIdentity.hash(Data(asset.id.utf8)) + ".wav" }

    @MainActor func testInterruptedDownloadReconstructsStoreAndRetriesOnlyUnfinishedAssets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { InterruptedAudioProtocol.handler = nil; try? FileManager.default.removeItem(at: folder) }
        let (_, local, remote, job, data) = try await fixture(folder)
        let root = folder.appendingPathComponent("Companion")
        let store = CompanionStore(root: root, client: try client())
        store.books = [remote]; store.jobs = [job]
        var requests: [String: Int] = [:]
        InterruptedAudioProtocol.handler = { request in
            let path = request.url!.path
            requests[path, default: 0] += 1
            if path == job.assets[1].url { return .interrupted(Data(data.prefix(80))) }
            return .complete(data)
        }
        let initial = await store.download(job, localBook: local)
        XCTAssertFalse(initial)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.orderedDownloads(jobID: job.id).map(\.asset.id), [job.assets[0].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(file(job.assets[1])).path))
        XCTAssertNil(requests[job.assets[2].url], "The interrupted transfer must stop the download loop")

        // Reconstruct the durable store, not a claimed physical app force-quit.
        let restored = CompanionStore(root: root, client: try client())
        XCTAssertEqual(restored.orderedDownloads(jobID: job.id).map(\.asset.id), [job.assets[0].id])
        XCTAssertEqual(restored.jobs.first?.segmentIds, job.segmentIds)
        InterruptedAudioProtocol.handler = { request in
            requests[request.url!.path, default: 0] += 1
            return .complete(data)
        }
        let retried = await restored.download(job, localBook: local)
        XCTAssertTrue(retried)
        XCTAssertNil(restored.error)
        XCTAssertEqual(requests[job.assets[0].url], 1, "The verified first asset must be reused after reconstructing the store")
        XCTAssertEqual(requests[job.assets[1].url], 2)
        XCTAssertEqual(requests[job.assets[2].url], 1)
        XCTAssertEqual(restored.orderedDownloads(jobID: job.id).map(\.asset.id), job.assets.map(\.id))
        XCTAssertEqual(Set(restored.downloads.map(\.id)).count, 3)
        for asset in job.assets {
            XCTAssertEqual(SourceIdentity.hash(try Data(contentsOf: root.appendingPathComponent(file(asset)))), asset.sha256)
        }
    }

    @MainActor func testFailedRepairCannotOfferOrPlayCorruptButDecodableAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { InterruptedAudioProtocol.handler = nil; try? FileManager.default.removeItem(at: folder) }
        let (library, local, remote, originalJob, data) = try await fixture(folder)
        var job = originalJob; job.assets = [job.assets[0]]; job.segmentIds = [job.segmentIds[0]]; job.totalSegments = 1; job.completedSegments = 1
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"), client: try client())
        store.books = [remote]; store.jobs = [job]
        InterruptedAudioProtocol.handler = { _ in .complete(data) }
        let downloaded = await store.download(job, localBook: local)
        XCTAssertTrue(downloaded)
        let record = try XCTUnwrap(store.orderedDownloads(jobID: job.id).first)
        let url = store.root.appendingPathComponent(record.file)
        let modificationDate = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var corrupted = data; corrupted[corrupted.count - 1] ^= 0x01
        try corrupted.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: url).duration, 0, "The fixture must still decode, so decoder failure cannot substitute for integrity checking")
        InterruptedAudioProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let repaired = await store.download(job, localBook: local)
        XCTAssertFalse(repaired)
        XCTAssertTrue(store.orderedDownloads(jobID: job.id).isEmpty)
        XCTAssertTrue(store.downloadedChapterGroups(for: local).isEmpty)
        let player = PlaybackController(); defer { player.stop() }
        store.play(record, library: library, player: player)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.error?.contains("retry its download") == true)

        InterruptedAudioProtocol.handler = { _ in .complete(data) }
        let recovered = await store.download(job, localBook: local)
        XCTAssertTrue(recovered)
        store.play(record, library: library, player: player)
        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.error)
        player.pause()
        // Even unchanged size/modtime cannot let a stale listing cache authorize playback.
        _ = store.orderedDownloads(jobID: job.id)
        let repairedDate = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try corrupted.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: repairedDate], ofItemAtPath: url.path)
        store.play(record, library: library, player: player)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNotNil(player.error)
    }

    @MainActor func testActualAudioCompletionStopsBeforeMissingRequiredPassage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, local, remote, job, data) = try await fixture(folder)
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        store.books = [remote]; store.jobs = [job]
        for index in [0, 2] {
            let name = "tone-\(index).wav"
            try data.write(to: store.root.appendingPathComponent(name))
            store.downloads.append(.init(localBookID: local.id, jobID: job.id, asset: job.assets[index], file: name, segment: remote.segments[index]))
        }
        XCTAssertEqual(store.orderedDownloads(jobID: job.id).map(\.asset.id), [job.assets[0].id, job.assets[2].id])
        let player = PlaybackController(); defer { player.stop() }
        let first = try XCTUnwrap(store.orderedDownloads(jobID: job.id).first)
        store.play(first, library: library, player: player)
        XCTAssertTrue(player.isPlaying)
        for _ in 0..<60 {
            if player.error != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.error?.contains("next passage") == true)
        XCTAssertEqual(library.book(local.id)?.audioAssetID, first.id, "Actual end-of-file must not advance to passage three across the missing second passage")
        try FileManager.default.removeItem(at: store.root.appendingPathComponent(first.file))
        store.playDownloadedTake(jobID: job.id, library: library, player: player)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.error?.contains("needed to resume") == true)
        XCTAssertEqual(library.book(local.id)?.audioAssetID, first.id, "A missing resume passage must not fall back silently to the later available recording")
        try data.write(to: store.root.appendingPathComponent(first.file))
        try data.write(to: store.root.appendingPathComponent("tone-1.wav"))
        let middle = DownloadRecord(localBookID: local.id, jobID: job.id, asset: job.assets[1], file: "tone-1.wav", segment: remote.segments[1])
        store.downloads.append(middle)
        let last = try XCTUnwrap(store.downloads.first { $0.asset.id == job.assets[2].id })
        store.playDownloadedTake(jobID: job.id, library: library, player: player)
        for _ in 0..<60 {
            if library.book(local.id)?.audioAssetID == last.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.book(local.id)?.audioAssetID, last.id, "Restoring the gap must allow real end-of-file advancement through the same take")
        XCTAssertNil(player.error)
    }
}
