import AVFoundation
import XCTest
@testable import BookPocketOpen

final class PlaybackSessionTests: XCTestCase {
    @MainActor func testDownloadedAudioStartsAfterSwitchingFromRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        let previousCategory = session.category
        let previousMode = session.mode
        let previousOptions = session.categoryOptions
        let player = PlaybackController()
        defer {
            player.stop()
            try? session.setActive(false)
            try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }

        // Simulate the category left by voice recording without activating a microphone.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav"))
        let book = LocalBook(id: "playback-session-fixture", title: "Transport tone - not speech", author: "Test", language: "en", sourceFile: "unused.txt", readingFile: "unused.txt", sourceSHA256: "test-only")

        // Exercise the actual session activation and AVAudioPlayer path, not a mock.
        try player.play(url: url, book: book)
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertEqual(player.bookID, book.id)
    }
}
