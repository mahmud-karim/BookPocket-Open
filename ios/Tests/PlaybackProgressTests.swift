import XCTest
import MediaPlayer
@testable import BookPocketOpen

final class PlaybackProgressTests: XCTestCase {
    @MainActor func testDownloadedJoinedTakeResumesInsideAssetAndReplaysAfterActualCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root.appendingPathComponent("Library"))
        let epub = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lantern", withExtension: "epub"))
        var local = try await library.importBook(epub)
        let store = CompanionStore(root: root.appendingPathComponent("Companion"))
        let segments = ["The Lantern", "Mira opened the brass lantern. A small blue light filled the room."].enumerated().map { index, text in
            RemoteSegment(id: "source-\(index)", text: text, kind: "paragraph", locator: .object(["href": .string("EPUB/chapter1.xhtml"), "type": .string("application/xhtml+xml"), "text": .object(["highlight": .string(text)])]))
        }
        let remote = RemoteBook(id: "original-book", title: local.title, author: "Original test fixture", language: "en", sourceSha256: local.sourceSHA256,
            chapters: [.init(id: "chapter", title: "The Lantern", href: "EPUB/chapter1.xhtml", segments: segments)])
        let tone = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav"))
        let bytes = try Data(contentsOf: tone)
        let assets = segments.enumerated().map { index, segment in
            AudioAsset(id: "audio-\(index)", segmentId: segment.id, mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(bytes), bytes: bytes.count, url: "/explicit-test-tone-not-speech", timings: [.init(start: 0, end: 0.25, startOffset: 0, endOffset: segment.text.unicodeScalars.count)])
        }
        let job = RemoteJob(id: "joined-take", bookId: remote.id, status: "completed", engine: "test-only-pcm-tone", voiceId: "not-a-voice", segmentIds: segments.map(\.id), completedSegments: 2, totalSegments: 2, assets: assets)
        store.books = [remote]; store.jobs = [job]
        for index in assets.indices {
            let file = "tone-\(index).wav"; try bytes.write(to: store.root.appendingPathComponent(file))
            store.downloads.append(.init(localBookID: local.id, jobID: job.id, asset: assets[index], file: file, segment: segments[index]))
        }
        let first = store.downloads[0], last = store.downloads[1]
        local.audioAssetID = last.id; local.audioSeconds = 0.12; library.update(local)
        let player = PlaybackController(), previousRate = player.rate
        defer { player.stop(); player.rate = previousRate }
        player.rate = 1
        store.playDownloadedTake(jobID: job.id, library: library, player: player)
        player.pause()
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(player.elapsed, 0.37, accuracy: 0.001, "An asset-local saved position restores into the single global timeline")
        XCTAssertEqual(library.book(local.id)?.audioAssetID, last.id)
        XCTAssertEqual(try XCTUnwrap(library.book(local.id)?.audioSeconds), 0.12, accuracy: 0.001)
        let finished = expectation(description: "Actual joined recording finishes and stores its final source position")
        let persistFinished = player.onFinished
        player.onFinished = { persistFinished?(); finished.fulfill() }
        player.resume(); await fulfillment(of: [finished], timeout: 4)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.elapsed, 0.5, accuracy: 0.001)
        XCTAssertEqual(library.book(local.id)?.audioAssetID, last.id)
        XCTAssertEqual(try XCTUnwrap(library.book(local.id)?.audioSeconds), 0.25, accuracy: 0.001)
        store.playDownloadedTake(jobID: job.id, library: library, player: player)
        XCTAssertTrue(player.isPlaying, "Selecting a completed download must replay, not seek a fresh item to its end")
        XCTAssertEqual(player.elapsed, 0, accuracy: 0.001); XCTAssertEqual(player.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(library.book(local.id)?.audioAssetID, first.id)
        player.pause(); try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.elapsed, 0, accuracy: 0.02)
    }
    @MainActor func testContinuousRecordingUsesOneTimelineAcrossAssetBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.wav"), second = root.appendingPathComponent("second.wav")
        try tone(seconds: 2).write(to: first); try tone(seconds: 3).write(to: second)
        let player = PlaybackController(), previousRate = UserDefaults.standard.double(forKey: "playbackRate")
        defer { player.stop(); UserDefaults.standard.set(previousRate, forKey: "playbackRate"); try? FileManager.default.removeItem(at: root) }
        player.rate = 1
        let book = LocalBook(id: "joined-fixture", title: "Original joined PCM tones — not speech", author: "Test", language: "en", sourceFile: "unused.txt", readingFile: "unused.txt", sourceSHA256: "test-only")
        try player.play(parts: [.init(url: first), .init(url: second)], book: book, recordingID: "one-take")
        XCTAssertEqual(player.duration, 5, accuracy: 0.01)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 5)
        player.pause(); player.seek(2.75)
        XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.elapsed, 2.75, accuracy: 0.01)
        let position = try XCTUnwrap(player.recordingPosition(at: player.elapsed))
        XCTAssertEqual(position.index, 1); XCTAssertEqual(position.seconds, 0.75, accuracy: 0.01)
        player.rate = 1.5; XCTAssertFalse(player.isPlaying, "Rate changes must not resume a paused composed recording")
        player.skip(-1); XCTAssertEqual(player.elapsed, 1.75, accuracy: 0.01); XCTAssertEqual(player.recordingPosition(at: player.elapsed)?.index, 0)
        player.skip(1); XCTAssertEqual(player.elapsed, 2.75, accuracy: 0.01)
        try await Task.sleep(for: .milliseconds(800)); XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.elapsed, 2.75, accuracy: 0.01)
        player.rate = 1; player.seek(1.8)
        let crossing = expectation(description: "One item crosses original asset boundary without resetting")
        player.onProgress = { seconds in
            if seconds > 2.2 { XCTAssertEqual(player.duration, 5, accuracy: 0.01); XCTAssertEqual(player.recordingID, "one-take"); crossing.fulfill(); player.onProgress = nil }
        }
        var finished = 0
        let end = expectation(description: "One finish for the complete recording")
        player.onFinished = { finished += 1; end.fulfill() }
        player.resume(); await fulfillment(of: [crossing, end], timeout: 7)
        XCTAssertEqual(finished, 1); XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.elapsed, 5, accuracy: 0.01)
        XCTAssertEqual(player.duration, 5, accuracy: 0.01)
        // An outstanding seek completion and old end notification cannot revive
        // transport after stop, narrator replacement, or source navigation.
        player.seek(1); player.stop(); try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.duration, 0); XCTAssertEqual(player.elapsed, 0)
        XCTAssertEqual(finished, 1)
    }
    @MainActor func testSelectedRecordingBoundsExcludeNeighboringSourcesAndUseAssetLocalTiming() async throws {
        let tone = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav"))
        let bytes = try Data(contentsOf: tone)
        let segment = RemoteSegment(id: "original", text: "ABCDE", kind: "paragraph", locator: .object([:]))
        let asset = AudioAsset(id: "audio", segmentId: segment.id, mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(bytes), bytes: bytes.count, url: "/test-only", timings: [.init(start: 0.05, end: 0.20, startOffset: 1, endOffset: 4)])
        let job = RemoteJob(id: "take", bookId: "book", status: "completed", engine: "test-only", voiceId: "no-voice", segmentIds: [segment.id, "neighboring-chapter"], completedSegments: 2, totalSegments: 2, assets: [asset])
        let record = DownloadRecord(localBookID: "local", jobID: job.id, asset: asset, file: "unused", segment: segment)
        let source = ReaderSourceSelection(title: "Page", ranges: [.init(segmentId: segment.id, startOffset: 1, endOffset: 4)], excerpts: ["BCD"])
        let selected = try DownloadedRecordingSelection.reader(job: job, selection: source, records: [record])
        XCTAssertEqual(selected.records.map(\.asset.id), [asset.id]); XCTAssertEqual(selected.duration, 0.15, accuracy: 0.001)
        let player = PlaybackController(); defer { player.stop() }
        let book = LocalBook(id: "local", title: "Original test tone", author: "Test", language: "en", sourceFile: "unused.txt", readingFile: "unused.txt", sourceSHA256: "test-only")
        try player.play(parts: [.init(url: tone, start: selected.bounds[0].start, end: selected.bounds[0].end)], book: book)
        player.pause(); player.seek(0.1)
        XCTAssertEqual(player.duration, 0.15, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(player.recordingPosition(at: 0.1)).seconds, 0.15, accuracy: 0.001)
        var unaligned = record; unaligned.asset.timings = []
        XCTAssertThrowsError(try DownloadedRecordingSelection.reader(job: job, selection: source, records: [unaligned]), "Never guess timestamps for a partial source selection")
    }
    private func tone(seconds: Int) -> Data {
        let rate = 8_000, count = rate * seconds
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for sample in 0..<count { word(Int16(sin(2 * .pi * 220 * Double(sample) / Double(rate)) * 200)) }
        return data
    }
    @MainActor func testPausedAudioDoesNotPullReaderBackButExplicitSeekAndResumePublishProgress() async throws {
        // An original, generated PCM transport tone, never a speech capability.
        let rate = 8_000, count = rate * 10
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for sample in 0..<count { word(Int16(sin(2 * .pi * 220 * Double(sample) / Double(rate)) * 200)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        let player = PlaybackController()
        let previousRate = player.rate
        defer { player.stop(); player.rate = previousRate; try? FileManager.default.removeItem(at: url) }
        player.rate = 1
        let book = LocalBook(id: "progress-fixture", title: "Transport tone — not speech", author: "Test", language: "en", sourceFile: "unused.txt", readingFile: "unused.txt", sourceSHA256: "test-only")
        try player.play(url: url, book: book)
        XCTAssertTrue(player.isPlaying)
        var updates: [Double] = []
        let playing = expectation(description: "Real playback emits progress")
        player.onProgress = { position in
            if updates.isEmpty { playing.fulfill() }
            updates.append(position)
        }
        await fulfillment(of: [playing], timeout: 3)
        player.pause()
        let pausedCount = updates.count, pausedPosition = player.elapsed
        // More than two transport ticks: manual reader navigation must stay put.
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(updates.count, pausedCount)
        XCTAssertEqual(player.elapsed, pausedPosition, accuracy: 0.001)
        player.pause()
        XCTAssertEqual(updates.count, pausedCount, "Repeated interruption or route-loss pause must not move the reader back")
        XCTAssertEqual(player.elapsed, pausedPosition, accuracy: 0.001)
        player.seek(4)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(updates.count, pausedCount + 1)
        XCTAssertEqual(try XCTUnwrap(updates.last), 4, accuracy: 0.01)
        let resumed = expectation(description: "Resumed real playback emits a new position")
        player.onProgress = { position in if position > 4 { resumed.fulfill(); player.onProgress = nil } }
        player.resume()
        XCTAssertTrue(player.isPlaying)
        await fulfillment(of: [resumed], timeout: 3)
    }
}
