import XCTest
@testable import BookPocketOpen

final class PlaybackProgressTests: XCTestCase {
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
