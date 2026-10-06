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
        if ProcessInfo.processInfo.arguments.contains("--reader-player-fixture") {
            try installReaderTakes(local: local, companion: companion)
            if ProcessInfo.processInfo.arguments.contains("--studio-failed-jobs-fixture"), var failed = companion.jobs.first {
                failed.id = "studio-failed-fixture"; failed.status = "failed"; failed.error = "Explicit offline test failure"; failed.assets = []; failed.completedSegments = 0
                var cancelled = failed; cancelled.id = "studio-cancelled-fixture"; cancelled.status = "cancelled"; cancelled.error = nil
                companion.jobs.insert(contentsOf: [failed, cancelled], at: 0)
            }
            return
        }
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
        let first = RemoteJob(id: "transport-job", bookId: remote.id, status: "completed", engine: "test-only-pcm-tone", voiceId: "not-a-voice", segmentIds: [segments[0].id], completedSegments: 1, totalSegments: 1, assets: [assets[0]], createdAt: "2026-01-01T00:00:00Z")
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

    /// Exact original EPUB text, with test-only transport recordings. Voice/mode
    /// snapshots exercise offline classification, never an installed engine or TTS.
    private static func installReaderTakes(local: LocalBook, companion: CompanionStore) throws {
        let text = [
            ["The Lantern", "Mira opened the brass lantern. A small blue light filled the room.", "“Can you hear me?” she asked. The answer arrived with a chime: “Yes, Mira.”", "A compass 🧭 pointed north; café bells sounded beyond the window."],
            ["Across the Bridge", "At dawn, Mira crossed the bridge. Below her, the river carried leaves toward the sea.", "“We have time,” said Rowan. “Then let us walk,” Mira replied.", "The lantern dimmed, but its light never disappeared."]
        ]
        let chapters = text.enumerated().map { index, passages in
            RemoteChapter(id: "reader-chapter-\(index)", title: passages[0], href: "EPUB/chapter\(index + 1).xhtml", segments: passages.enumerated().map { offset, text in
                RemoteSegment(id: "reader-source-\(index)-\(offset)", text: text, kind: offset == 0 ? "heading" : "paragraph", locator: .object(["href": .string("EPUB/chapter\(index + 1).xhtml"), "type": .string("application/xhtml+xml"), "text": .object(["highlight": .string(text)])]))
            })
        }
        let book = RemoteBook(id: "reader-tone-book", title: local.title, author: "Original transport fixture", language: "en", sourceSha256: local.sourceSHA256, chapters: chapters)
        var jobs: [RemoteJob] = [], records: [DownloadRecord] = []
        for (index, chapter) in chapters.enumerated() {
            let mode = index == 0 ? "single" : "full_cast"
            let data = tone(seconds: index == 0 ? 90 : 120, frequency: index == 0 ? 220 : 330)
            let file = "reader-tone-\(index).wav"; try data.write(to: companion.root.appendingPathComponent(file), options: .atomic)
            let assets = chapter.segments.map { segment in
                AudioAsset(id: "reader-tone-" + segment.id, segmentId: segment.id, mediaType: "audio/wav", duration: index == 0 ? 90 : 120, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/explicit-test-tone-not-speech", timings: scalarTimings(segment.text, seconds: index == 0 ? 90 : 120), narrationMode: mode, castSpans: [])
            }
            let job = RemoteJob(id: "reader-tone-job-\(index)", bookId: book.id, status: "completed", engine: "voicestudio", voiceId: "test-only-voice-snapshot-not-an-installed-voice", segmentIds: chapter.segments.map(\.id), completedSegments: assets.count, totalSegments: assets.count, assets: assets, createdAt: "2026-01-01T00:00:00Z", narrationMode: mode, narrationPlan: [], voiceName: "Kyon")
            jobs.append(job)
            for (asset, segment) in zip(assets, chapter.segments) { records.append(.init(localBookID: local.id, jobID: job.id, asset: asset, file: file, segment: segment)) }
        }
        var otherBook = book; otherBook.id = "reader-other-book"; otherBook.sourceSha256 = String(repeating: "f", count: 64)
        var other = jobs[0]; other.id = "reader-other-job"; other.bookId = otherBook.id
        companion.books = [book, otherBook]; companion.jobs = jobs + [other]; companion.downloads = records
        if ProcessInfo.processInfo.arguments.contains("--reader-continuous-fixture") || ProcessInfo.processInfo.arguments.contains("--reader-narration-tools-fixture") {
            // A complete chapter and a page excerpt each contain several actual
            // WAV assets. They exercise joined transport, not a speech engine.
            let chapter = chapters[0], selected = Array(chapter.segments.prefix(3))
            // Keep the first natural boundary quick, with ample remaining audio
            // for native gestures on cold or overloaded Simulator runners.
            let short = tone(seconds: 4, frequency: 220), long = tone(seconds: 60, frequency: 220)
            let shortFile = "reader-continuous-short.wav", longFile = "reader-continuous-long.wav"
            try short.write(to: companion.root.appendingPathComponent(shortFile), options: .atomic)
            try long.write(to: companion.root.appendingPathComponent(longFile), options: .atomic)
            let assets = selected.enumerated().map { index, segment in
                let data = index == 0 ? short : long, seconds = index == 0 ? 4.0 : 60.0
                return AudioAsset(id: "reader-continuous-" + segment.id, segmentId: segment.id, mediaType: "audio/wav", duration: seconds, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/explicit-test-tone-not-speech", timings: scalarTimings(segment.text, seconds: seconds), narrationMode: "single", castSpans: [])
            }
            let page = RemoteJob(id: "reader-continuous-page", bookId: book.id, status: "completed", engine: "omnivoice", voiceId: "test-only-tone", segmentIds: selected.map(\.id), completedSegments: 3, totalSegments: 3, assets: assets, createdAt: "2026-01-01T00:00:00Z", narrationMode: "single", voiceName: "Kyon")
            var whole = page; whole.id = "reader-continuous-chapter"
            whole.segmentIds = chapter.segments.map(\.id); whole.completedSegments = 4; whole.totalSegments = 4
            let last = chapter.segments[3]
            whole.assets.append(.init(id: "reader-continuous-last", segmentId: last.id, mediaType: "audio/wav", duration: 60, sha256: SourceIdentity.hash(long), bytes: long.count, url: "/explicit-test-tone-not-speech", timings: scalarTimings(last.text, seconds: 60), narrationMode: "single", castSpans: []))
            companion.jobs = [page, whole]
            companion.downloads = [page, whole].flatMap { job in job.assets.map { asset in
                DownloadRecord(localBookID: local.id, jobID: job.id, asset: asset, file: asset.duration == 4 ? shortFile : longFile, segment: chapter.segments.first { $0.id == asset.segmentId })
            } }
            if ProcessInfo.processInfo.arguments.contains("--reader-narration-tools-fixture") {
                // Explicit transport fixture metadata only, not acoustic speech
                // alignment. Long intervals make native seek/word assertions
                // deterministic even on overloaded Simulator runners.
                for jobIndex in companion.jobs.indices {
                    for assetIndex in companion.jobs[jobIndex].assets.indices {
                        var asset = companion.jobs[jobIndex].assets[assetIndex]
                        guard let source = chapter.segments.first(where: { $0.id == asset.segmentId }) else { continue }
                        asset.sourceTimings = asset.timings; asset.alignment = "word"
                        let words = assetIndex == 0 ? ["The", "Lantern"] : assetIndex == 1 ? ["Mira", "opened"] : assetIndex == 2 ? ["Can", "you"] : ["compass", "café"]
                        asset.timings = words.enumerated().compactMap { index, word in
                            guard let range = source.text.range(of: word) else { return nil }
                            return AudioTiming(start: index == 0 ? 0 : asset.duration / 2, end: index == 0 ? asset.duration / 2 : asset.duration,
                                startOffset: source.text[..<range.lowerBound].unicodeScalars.count, endOffset: source.text[..<range.upperBound].unicodeScalars.count)
                        }
                        companion.jobs[jobIndex].assets[assetIndex] = asset
                    }
                }
                for index in companion.downloads.indices {
                    if let asset = companion.jobs.first(where: { $0.id == companion.downloads[index].jobID })?.assets.first(where: { $0.id == companion.downloads[index].asset.id }) { companion.downloads[index].asset = asset }
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--reader-alternate-takes-fixture") {
            var alternate = jobs[0]; alternate.id = "reader-alternate-job"
            companion.jobs.append(alternate)
            companion.downloads += records.filter { $0.jobID == jobs[0].id }.map {
                var record = $0; record.jobID = alternate.id; return record
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--reader-page-clips-fixture") {
            // Deliberately no complete chapter take. Both clips use exact EPUB
            // spans; the second has PC metadata only and cannot play offline.
            let segment = chapters[0].segments[1]
            let data = tone(seconds: 30, frequency: 220)
            let file = "reader-page-clip.wav"; try data.write(to: companion.root.appendingPathComponent(file), options: .atomic)
            var clips: [RemoteJob] = []
            for index in 0..<2 {
                let start = index == 0 ? 0 : 27, end = index == 0 ? 27 : segment.text.unicodeScalars.count
                let asset = AudioAsset(id: "reader-page-audio-\(index)", segmentId: segment.id, mediaType: "audio/wav", duration: 30, sha256: SourceIdentity.hash(data), bytes: data.count, url: "/explicit-test-tone-not-speech", timings: [], sourceStart: start, sourceEnd: end, narrationMode: "single", castSpans: [])
                let clip = RemoteJob(id: "reader-page-job-\(index)", bookId: book.id, status: "completed", engine: "omnivoice", voiceId: "test-only-voice-snapshot-not-an-installed-voice", segmentIds: [segment.id], completedSegments: 1, totalSegments: 1, assets: [asset], createdAt: "2026-01-0\(index + 1)T00:00:00Z", sourceRanges: [.init(segmentId: segment.id, startOffset: start, endOffset: end)], narrationMode: "single", narrationPlan: [], voiceName: "Kyon")
                clips.append(clip)
                if index == 0 { companion.downloads = [.init(localBookID: local.id, jobID: clip.id, asset: asset, file: file, segment: segment)] }
            }
            companion.jobs = clips
        }
    }

    private static func scalarTimings(_ text: String, seconds: Double) -> [AudioTiming] {
        let count = text.unicodeScalars.count
        return (0..<count).map { .init(start: seconds * Double($0) / Double(count), end: seconds * Double($0 + 1) / Double(count), startOffset: $0, endOffset: $0 + 1) }
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
