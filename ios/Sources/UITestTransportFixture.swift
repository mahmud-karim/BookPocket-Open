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
        let first = RemoteJob(id: "transport-job", bookId: remote.id, status: "completed", engine: "test-only-pcm-tone", voiceId: "not-a-voice", segmentIds: [segments[0].id, segments[2].id], completedSegments: 2, totalSegments: 2, assets: [assets[0], assets[2]], createdAt: "2026-01-01T00:00:00Z")
        let second = RemoteJob(id: "transport-second-job", bookId: remote.id, status: "completed", engine: "test-only-pcm-tone", voiceId: "not-a-voice", segmentIds: [segments[1].id], completedSegments: 1, totalSegments: 1, assets: [assets[1]], createdAt: "2026-01-02T00:00:00Z")
        records[1].jobID = second.id
        var excerptAsset = assets[0]; excerptAsset.id = "transport-excerpt-audio"; excerptAsset.sourceStart = 0; excerptAsset.sourceEnd = 4
        let excerpt = RemoteJob(id: "transport-excerpt-job", bookId: remote.id, status: "completed", engine: "test-only-pcm-tone", voiceId: "alternate-test-tone", segmentIds: [segments[0].id], completedSegments: 1, totalSegments: 1, assets: [excerptAsset], createdAt: "2026-01-03T00:00:00Z", sourceRanges: [.init(segmentId: segments[0].id, startOffset: 0, endOffset: 4)])
        records.append(.init(localBookID: local.id, jobID: excerpt.id, asset: excerptAsset, file: records[0].file, segment: segments[0]))
        var other = remote; other.id = "other-book"; other.sourceSha256 = String(repeating: "b", count: 64)
        other.chapters[0].title = "Different book chapter"
        var otherJob = first; otherJob.id = "other-job"; otherJob.bookId = other.id
        var otherRecord = records[0]; otherRecord.localBookID = "other-local-book"; otherRecord.jobID = otherJob.id
        records.append(otherRecord)
        companion.books = [remote, other]
        companion.jobs = [first, second, excerpt, otherJob]
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
