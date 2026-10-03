import XCTest
import SQLite3
import ReadiumZIPFoundation
@testable import BookPocketOpen

final class ProjectImportRecoveryTests: XCTestCase {
    private struct Project: Encodable {
        var formatVersion = 1
        var book: RemoteBook
        var job: RemoteJob
    }
    private struct Fixture {
        var project: Project
        var source: Data
        var audio: [String: Data]
    }
    private enum Damage { case none, missingLast, corruptLast }

    private func fixture(_ name: String) throws -> Fixture {
        let segments = (0..<2).map { RemoteSegment(id: "\(name)-segment-\($0)", text: "Original \(name) passage \($0).", kind: "paragraph", locator: .object([:])) }
        let source = Data(segments.map(\.text).joined(separator: "\n\n").utf8)
        let tone = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        var second = tone; second[second.count - 1] ^= 0x02
        let book = RemoteBook(id: name, title: "Original archive \(name)", author: "Test", language: "en", sourceSha256: SourceIdentity.hash(source), chapters: [.init(id: "\(name)-chapter", title: "Original chapter", href: "text.xhtml", segments: segments)])
        let assets = [tone, second].enumerated().map { index, data in
            AudioAsset(id: "\(name)-audio-\(index)", segmentId: segments[index].id, mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/v1/assets/\(name)-audio-\(index)", timings: [])
        }
        let job = RemoteJob(id: name + "-job", bookId: book.id, status: "completed", engine: "test-only-pcm", voiceId: "not-a-voice", segmentIds: segments.map(\.id), completedSegments: 2, totalSegments: 2, assets: assets)
        return Fixture(project: Project(book: book, job: job), source: source, audio: [assets[0].id: tone, assets[1].id: second])
    }
    private func archive(_ fixture: Fixture, in folder: URL, damage: Damage = .none) async throws -> URL {
        let staging = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let manifest = staging.appendingPathComponent("project.json")
        let source = staging.appendingPathComponent("source.txt")
        try CompanionClient.encoder.encode(fixture.project).write(to: manifest)
        try fixture.source.write(to: source)
        let url = staging.appendingPathComponent("project.zip")
        let zip = try await Archive(url: url, accessMode: .create)
        try await zip.addEntry(with: "project.json", fileURL: manifest)
        try await zip.addEntry(with: "source.txt", fileURL: source)
        for (index, asset) in fixture.project.job.assets.enumerated() {
            let isLast = index == fixture.project.job.assets.count - 1
            if isLast && damage == .missingLast { continue }
            var data = try XCTUnwrap(fixture.audio[asset.id])
            if isLast && damage == .corruptLast { data[data.count - 1] ^= 0x04 }
            let file = staging.appendingPathComponent("tone-\(index).wav")
            try data.write(to: file)
            try await zip.addEntry(with: "audio/\(asset.id).wav", fileURL: file)
        }
        return url
    }
    private func sql(_ statement: String, database url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw BookError.message("Test database could not open") }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw BookError.message(String(cString: sqlite3_errmsg(connection))) }
    }

    @MainActor func testLateCorruptOrMissingAudioLeavesNoPartialImportAndPreservesSharedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        let seed = try fixture("seed")
        try await store.importProject(archive(seed, in: folder), library: library)
        let previousIDs = store.downloads.map(\.id)
        let previousFiles = try Dictionary(uniqueKeysWithValues: store.downloads.map { ($0.file, try Data(contentsOf: store.root.appendingPathComponent($0.file))) })
        let incoming = try fixture("incoming")
        for damage in [Damage.corruptLast, .missingLast] {
            let url = try await archive(incoming, in: folder, damage: damage)
            do { try await store.importProject(url, library: library); XCTFail("Every asset must validate before publication") }
            catch { XCTAssertTrue(error.localizedDescription.contains(damage == .missingLast ? "missing expected audio" : "checksum")) }
            XCTAssertEqual(library.books.count, 1, "Late validation failure must precede even the original-book import")
            XCTAssertEqual(store.downloads.map(\.id), previousIDs)
            XCTAssertEqual(store.books.map(\.id), [seed.project.book.id])
            XCTAssertEqual(store.jobs.map(\.id), [seed.project.job.id])
            let reconstructed = CompanionStore(root: store.root)
            XCTAssertEqual(reconstructed.downloads.map(\.id), previousIDs)
            XCTAssertEqual(reconstructed.jobs.map(\.id), [seed.project.job.id])
            for (file, bytes) in previousFiles { XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(file)), bytes) }
        }
    }

    @MainActor func testSQLWriteFailureRollsBackImportMetadataAndAllowsCleanRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        let seed = try fixture("seed")
        try await store.importProject(archive(seed, in: folder), library: library)
        var incoming = try fixture("incoming")
        let distinctID = incoming.project.job.assets[1].id
        var distinctBytes = try XCTUnwrap(incoming.audio[distinctID]); distinctBytes[distinctBytes.count - 1] ^= 0x10
        incoming.audio[distinctID] = distinctBytes
        incoming.project.job.assets[1].sha256 = SourceIdentity.hash(distinctBytes)
        let incomingArchive = try await archive(incoming, in: folder)
        let previousIDs = store.downloads.map(\.id)
        let database = store.root.appendingPathComponent("companion.sqlite")
        // A real SQLite failure after downloads/books writes, entirely in the
        // test's temporary database. No production failpoint or observer exists.
        try sql("CREATE TRIGGER reject_test_job BEFORE UPDATE OF value ON records WHEN NEW.key = 'jobs' BEGIN SELECT RAISE(ABORT, 'test transaction rollback'); END", database: database)
        do { try await store.importProject(incomingArchive, library: library); XCTFail("The SQL failure must propagate") }
        catch { XCTAssertTrue(error.localizedDescription.contains("test transaction rollback")) }
        XCTAssertEqual(store.downloads.map(\.id), previousIDs)
        XCTAssertEqual(store.books.map(\.id), [seed.project.book.id])
        XCTAssertEqual(store.jobs.map(\.id), [seed.project.job.id])
        let reconstructed = CompanionStore(root: store.root)
        XCTAssertEqual(reconstructed.downloads.map(\.id), previousIDs)
        XCTAssertEqual(reconstructed.books.map(\.id), [seed.project.book.id])
        XCTAssertEqual(reconstructed.jobs.map(\.id), [seed.project.job.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Audio/" + SourceIdentity.hash(distinctBytes) + ".wav").path), "Failed publication must remove only newly installed, unreferenced files")
        XCTAssertEqual(library.books.count, 2, "A validated standalone original may remain after a companion transaction failure")
        let standaloneID = try XCTUnwrap(library.books.first { $0.sourceSHA256 == incoming.project.book.sourceSha256 }?.id)
        for record in store.downloads { XCTAssertEqual(SourceIdentity.hash(try Data(contentsOf: store.root.appendingPathComponent(record.file))), record.asset.sha256) }
        try sql("DROP TRIGGER reject_test_job", database: database)
        try await reconstructed.importProject(incomingArchive, library: library)
        XCTAssertEqual(library.books.count, 2)
        XCTAssertEqual(reconstructed.downloads.first { $0.jobID == incoming.project.job.id }?.localBookID, standaloneID)
        XCTAssertEqual(reconstructed.orderedDownloads(jobID: incoming.project.job.id).map(\.asset.id), incoming.project.job.assets.map(\.id))
    }

    @MainActor func testRepeatedImportKeepsIdentitiesAndRejectsConflictingSharedAssetBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        var original = try fixture("repeat")
        let expectedOrder = original.project.job.assets.map(\.id)
        original.project.job.assets.reverse() // Archive order is not playback order.
        let url = try await archive(original, in: folder)
        try await store.importProject(url, library: library)
        let sourceID = try XCTUnwrap(library.books.first?.id)
        let downloadIDs = store.downloads.map(\.id)
        let files = store.downloads.map(\.file)
        try await store.importProject(url, library: library)
        let reconstructed = CompanionStore(root: store.root)
        XCTAssertEqual(library.books.map(\.id), [sourceID])
        XCTAssertEqual(reconstructed.downloads.map(\.id), downloadIDs)
        XCTAssertEqual(reconstructed.downloads.map(\.file), files)
        XCTAssertEqual(reconstructed.jobs.map(\.id), [original.project.job.id])
        XCTAssertEqual(reconstructed.orderedDownloads(jobID: original.project.job.id).map(\.asset.id), expectedOrder)

        var conflicting = original
        conflicting.project.job.id = "conflicting-take"
        let id = conflicting.project.job.assets[0].id
        var changed = try XCTUnwrap(conflicting.audio[id]); changed[changed.count - 1] ^= 0x08
        conflicting.audio[id] = changed
        conflicting.project.job.assets[0].sha256 = SourceIdentity.hash(changed)
        let conflict = try await archive(conflicting, in: folder)
        do { try await store.importProject(conflict, library: library); XCTFail("One asset identity cannot acquire different bytes") }
        catch { XCTAssertTrue(error.localizedDescription.contains("existing identity")) }
        XCTAssertEqual(store.downloads.map(\.id), downloadIDs)
        XCTAssertEqual(store.jobs.map(\.id), [original.project.job.id])
        for record in store.downloads { XCTAssertEqual(SourceIdentity.hash(try Data(contentsOf: store.root.appendingPathComponent(record.file))), record.asset.sha256) }
    }

    @MainActor func testCompletedArchiveRequiresExactManifestCoverageAndValidWholeSourceTimings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        let original = try fixture("manifest")
        let changes: [(String, (inout Fixture) -> Void)] = [
            ("asset absent from manifest", { $0.project.job.assets.removeLast() }),
            ("duplicate selection", { $0.project.job.segmentIds[1] = $0.project.job.segmentIds[0] }),
            ("foreign selection", { $0.project.job.segmentIds[1] = "foreign" }),
            ("duplicate asset passage", { $0.project.job.assets[1].segmentId = $0.project.job.assets[0].segmentId }),
            ("additional asset passage", { $0.project.job.assets[1].segmentId = "foreign" }),
            ("asset without passage", { $0.project.job.assets[1].segmentId = nil }),
            ("zero duration", { $0.project.job.assets[1].duration = 0 }),
            ("timing outside original scalars", { value in
                value.project.job.assets[1].timings = [.init(start: 0, end: 0.1, startOffset: 0, endOffset: value.project.book.segments[1].text.unicodeScalars.count + 1)]
            }),
            ("timing outside audio", { $0.project.job.assets[1].timings = [.init(start: 0, end: 1, startOffset: 0, endOffset: 1)] })
        ]
        for (name, change) in changes {
            var damaged = original; change(&damaged)
            let url = try await archive(damaged, in: folder)
            do { try await store.importProject(url, library: library); XCTFail("Accepted \(name)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("manifest"), "\(name): \(error)") }
            XCTAssertTrue(store.jobs.isEmpty, name)
            XCTAssertTrue(store.downloads.isEmpty, name)
            XCTAssertTrue(library.books.isEmpty, name)
        }
        var nonfinite = original.project.job; nonfinite.assets[0].duration = .infinity
        XCTAssertThrowsError(try ProjectImportValidation.validate(job: nonfinite, book: original.project.book))
        nonfinite = original.project.job; nonfinite.assets[0].timings = [.init(start: .nan, end: 0.1, startOffset: 0, endOffset: 1)]
        XCTAssertThrowsError(try ProjectImportValidation.validate(job: nonfinite, book: original.project.book))

        // A complete page/excerpt selects only its declared scalar range, not all
        // segments in the original book. It remains a valid complete take.
        var page = original
        page.project.job.assets = [page.project.job.assets[0]]
        page.project.job.segmentIds = [page.project.job.segmentIds[0]]
        page.project.job.completedSegments = 1; page.project.job.totalSegments = 1
        page.project.job.sourceRanges = [.init(segmentId: page.project.job.segmentIds[0], startOffset: 2, endOffset: 8)]
        page.project.job.assets[0].sourceStart = 2; page.project.job.assets[0].sourceEnd = 8
        page.project.job.assets[0].timings = [.init(start: 0, end: 0.25, startOffset: 2, endOffset: 8)]
        let pageURL = try await archive(page, in: folder)
        try await store.importProject(pageURL, library: library)
        XCTAssertEqual(store.orderedDownloads(jobID: page.project.job.id).count, 1)
        XCTAssertEqual(store.jobs.first?.sourceRanges, page.project.job.sourceRanges)
    }

    @MainActor func testExistingAudioAndBookIdentitiesCannotChangeTheirSourceMappings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        let original = try fixture("identities")
        try await store.importProject(archive(original, in: folder), library: library)
        let previousIDs = store.downloads.map(\.id)
        let changes: [(String, (inout Fixture) -> Void)] = [
            ("audio source passage", { value in
                value.project.job.assets[0].segmentId = value.project.book.segments[1].id
                value.project.job.assets[1].segmentId = value.project.book.segments[0].id
            }),
            ("audio source bounds", { value in
                value.project.job.assets[0].sourceStart = 0
                value.project.job.assets[0].sourceEnd = value.project.book.segments[0].text.unicodeScalars.count
            }),
            ("audio byte count", { $0.project.job.assets[0].bytes += 1 }),
            ("audio duration", { $0.project.job.assets[0].duration = 0.5 }),
            ("audio timing", { $0.project.job.assets[0].timings = [.init(start: 0, end: 0.1, startOffset: 0, endOffset: 1)] }),
            ("original text", { $0.project.book.chapters[0].segments[0].text += " Changed." }),
            ("original order", { $0.project.book.chapters[0].segments.reverse() })
        ]
        for (name, change) in changes {
            var changed = original; changed.project.job.id = "new-take"; change(&changed)
            let url = try await archive(changed, in: folder)
            do { try await store.importProject(url, library: library); XCTFail("Accepted altered \(name)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("existing identity"), "\(name): \(error)") }
            XCTAssertEqual(store.downloads.map(\.id), previousIDs)
            XCTAssertEqual(store.jobs.map(\.id), [original.project.job.id])
            XCTAssertEqual(store.books.first?.segments.map(\.text), original.project.book.segments.map(\.text))
        }
        // Fresh take identity may reuse unchanged immutable audio.
        var alternate = original; alternate.project.job.id = "valid-alternate"
        try await store.importProject(archive(alternate, in: folder), library: library)
        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertEqual(store.orderedDownloads(jobID: alternate.project.job.id).map(\.asset.id), alternate.project.job.assets.map(\.id))
    }

    @MainActor func testSuccessfulImportRemovesOnlySupersededUnsharedOldAudioPaths() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let store = CompanionStore(root: folder.appendingPathComponent("Companion"))
        let original = try fixture("old-paths")
        let url = try await archive(original, in: folder)
        try await store.importProject(url, library: library)
        // Seed the pre-migration on-disk layout using only this temporary store.
        for index in store.downloads.indices {
            let old = store.root.appendingPathComponent(store.downloads[index].file)
            let legacyPath = "Audio/" + SourceIdentity.hash(Data(store.downloads[index].asset.id.utf8)) + ".wav"
            try FileManager.default.moveItem(at: old, to: store.root.appendingPathComponent(legacyPath))
            store.downloads[index].file = legacyPath
        }
        let oldPaths = store.downloads.map(\.file)
        var sharedJob = original.project.job
        sharedJob.id = "shared-old-path"; sharedJob.assets = [sharedJob.assets[0]]
        sharedJob.segmentIds = [sharedJob.segmentIds[0]]; sharedJob.totalSegments = 1; sharedJob.completedSegments = 1
        var sharedRecord = store.downloads[0]; sharedRecord.jobID = sharedJob.id
        store.jobs.append(sharedJob); store.downloads.append(sharedRecord)
        let database = try LibraryDatabase(url: store.root.appendingPathComponent("companion.sqlite"))
        try database.transaction {
            try database.write("downloads", value: store.downloads)
            try database.write("jobs", value: store.jobs)
        }
        let reconstructed = CompanionStore(root: store.root)
        try await reconstructed.importProject(url, library: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(oldPaths[0]).path), "Another take still owns the first old path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(oldPaths[1]).path), "The replaced unshared path must not remain orphaned")
        XCTAssertEqual(reconstructed.orderedDownloads(jobID: original.project.job.id).map(\.asset.id), original.project.job.assets.map(\.id))
        XCTAssertEqual(reconstructed.orderedDownloads(jobID: sharedJob.id).first?.file, oldPaths[0])
        let reopened = CompanionStore(root: store.root)
        XCTAssertEqual(reopened.downloads.map(\.id), reconstructed.downloads.map(\.id))
        for record in reopened.downloads { XCTAssertEqual(SourceIdentity.hash(try Data(contentsOf: store.root.appendingPathComponent(record.file))), record.asset.sha256) }
    }
}
