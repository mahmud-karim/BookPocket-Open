#if DEBUG
import Foundation

/// Offline transport coverage only. These locally composed tones are not TTS output,
/// and this harness never creates a pairing, voice, available engine, or network client.
@MainActor enum UITestTransportFixture {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--offline-transport-fixture")
    }

    static func install(library: LibraryStore, companion: CompanionStore) async throws {
        guard let source = Bundle.main.url(forResource: "lantern", withExtension: "epub") else {
            throw BookError.message("Original transport test publication is missing.")
        }
        var local = try await library.importBook(source)
        local.title = "Transport tone fixture — not speech"
        library.update(local)
        let titles = ["Tone one — 90 seconds", "Tone two — 120 seconds", "Unavailable tone"]
        let segments = titles.enumerated().map { index, title in
            RemoteSegment(id: "transport-segment-\(index)", text: title, kind: "test-only-tone", locator: .object([:]))
        }
        let remote = RemoteBook(id: "transport-fixture", title: local.title, author: "Original test tones", language: "en", sourceSha256: local.sourceSHA256,
            chapters: segments.enumerated().map { index, segment in
                RemoteChapter(id: "transport-chapter-\(index)", title: titles[index], href: "test-only-tone-\(index)", segments: [segment])
            })
        var assets: [AudioAsset] = []
        var records: [DownloadRecord] = []
        for index in 0..<3 {
            let seconds = index == 0 ? 90 : 120
            let data = tone(seconds: seconds, frequency: index == 0 ? 220 : 330)
            let file = "transport-\(index).wav"
            // The third record deliberately has no local file. It must not be
            // presented as an available downloaded chapter.
            if index < 2 { try data.write(to: companion.root.appendingPathComponent(file), options: .atomic) }
            let asset = AudioAsset(id: "transport-audio-\(index)", segmentId: segments[index].id, mediaType: "audio/wav", duration: Double(seconds), sha256: SourceIdentity.hash(data), bytes: data.count, url: "/test-only-unavailable-network", timings: [])
            assets.append(asset)
            records.append(DownloadRecord(localBookID: local.id, jobID: "transport-job", asset: asset, file: file, segment: segments[index]))
        }
        companion.books = [remote]
        companion.jobs = [RemoteJob(id: "transport-job", bookId: remote.id, status: "completed", engine: "test-only-pcm-tone", voiceId: "not-a-voice", segmentIds: segments.map(\.id), completedSegments: 3, totalSegments: 3, assets: assets)]
        companion.downloads = records
    }

    private static func tone(seconds: Int, frequency: Double) -> Data {
        let rate = 8_000, count = seconds * rate
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for sample in 0..<count {
            word(Int16(sin(2 * .pi * frequency * Double(sample) / Double(rate)) * 200))
        }
        return data
    }
}
#endif
