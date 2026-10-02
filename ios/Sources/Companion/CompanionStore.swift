import Foundation
import Observation
import ReadiumShared
import UIKit
import ReadiumZIPFoundation

@MainActor @Observable final class CompanionStore {
    var identity: CompanionIdentity?
    var engines: [RemoteEngine] = []
    var voices: [RemoteVoice] = []
    var jobs: [RemoteJob] = []
    var books: [RemoteBook] = []
    var downloads: [DownloadRecord] = []
    var pendingRequests: [GenerationRequest] = []
    var legacyRecordings: [LegacyRecording] = []
    var importedPronunciations: [PronunciationRule] = []
    var error: String?
    var status: String?
    var refreshing = false
    var downloading: String?
    var pairing = false
    var exporting = false
    var receivingBook = false
    var paired: Bool { identity != nil && client != nil }
    private var client: CompanionClient?
    private var database: LibraryDatabase?
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? URL.documentsDirectory.appendingPathComponent("Companion", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            database = try LibraryDatabase(url: self.root.appendingPathComponent("companion.sqlite"))
            identity = try database?.read("identity", as: CompanionIdentity.self)
            downloads = try database?.read("downloads", as: [DownloadRecord].self) ?? []
            books = try database?.read("books", as: [RemoteBook].self) ?? []
            jobs = try database?.read("jobs", as: [RemoteJob].self) ?? []
            pendingRequests = try database?.read("pendingRequests", as: [GenerationRequest].self) ?? []
            legacyRecordings = try database?.read("legacyRecordings", as: [LegacyRecording].self) ?? []
            importedPronunciations = try database?.read("pronunciations", as: [PronunciationRule].self) ?? []
            if let identity, let token = DeviceKeychain.read(account: identity.deviceID) { client = try CompanionClient(url: identity.url, fingerprint: identity.fingerprint, token: token) }
        } catch { self.error = error.localizedDescription }
    }
    private func persist() throws {
        guard let database else { throw BookError.message("Companion storage is unavailable.") }
        try database.write("identity", value: identity)
        try database.write("downloads", value: downloads)
        try database.write("books", value: books)
        try database.write("jobs", value: jobs)
        try database.write("pendingRequests", value: pendingRequests)
        try database.write("legacyRecordings", value: legacyRecordings)
        try database.write("pronunciations", value: importedPronunciations)
    }
    func connect(qr: PairingQR) async {
        pairing = true; status = "Requesting a secure connection…"
        defer { pairing = false }
        do {
            guard let url = URL(string: qr.url) else { throw BookError.message("Invalid companion address.") }
            let candidate = try CompanionClient(url: url, fingerprint: qr.certificateSha256)
            let body = try JSONSerialization.data(withJSONObject: ["code": qr.code, "device_name": "Book Pocket on " + UIDevice.current.model])
            let pending: PairingStatus = try await candidate.send("/v1/pairings", method: "POST", body: body)
            guard let id = pending.id, let poll = pending.pollToken else { throw BookError.message("The companion did not return a pairing request.") }
            status = "Approve this device in your PC's Studio."
            for _ in 0..<300 {
                try Task.checkCancellation()
                let result: PairingStatus = try await candidate.send("/v1/pairings/\(id)", bearer: poll)
                if result.status == "approved", let token = result.deviceToken, let device = result.deviceId {
                    try DeviceKeychain.save(token, account: device)
                    candidate.token = token
                    identity = CompanionIdentity(url: url, fingerprint: candidate.fingerprint, deviceID: device)
                    client = candidate; try persist(); status = "Paired securely"; await refresh(); return
                }
                if ["rejected", "expired"].contains(result.status) { throw BookError.message("Pairing \(result.status). Create a new code in your PC's Studio.") }
                try await Task.sleep(for: .seconds(2))
            }
            throw BookError.message("Pairing timed out. Create a new code in the PC Studio.")
        } catch is CancellationError { status = nil }
        catch { self.error = error.localizedDescription; status = nil }
    }
    func disconnect() async {
        do {
            if let client { try await client.command("/v1/devices/current") }
            if let identity { DeviceKeychain.remove(account: identity.deviceID) }
            identity = nil; client = nil; engines = []; voices = []; try persist(); status = nil
        } catch { self.error = error.localizedDescription }
    }
    func refresh(reportErrors: Bool = true) async {
        guard let client, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            struct Engines: Decodable { var engines: [RemoteEngine] }
            struct Voices: Decodable { var voices: [RemoteVoice] }
            struct Jobs: Decodable { var jobs: [RemoteJob] }
            struct Books: Decodable { var books: [RemoteBook] }
            struct Legacy: Decodable { var recordings: [LegacyRecording] }
            struct Pronunciations: Decodable { var pronunciationRules: [PronunciationRule] }
            async let e: Engines = client.send("/v1/engines")
            async let v: Voices = client.send("/v1/voices")
            async let j: Jobs = client.send("/v1/jobs")
            async let b: Books = client.send("/v1/books")
            async let l: Legacy = client.send("/v1/legacy-recordings")
            async let p: Pronunciations = client.send("/v1/pronunciations")
            let result = try await (e, v, j, b, l, p)
            engines = result.0.engines; voices = result.1.voices
            let downloadedJobIDs = Set(downloads.map(\.jobID))
            let remoteJobIDs = Set(result.2.jobs.map(\.id))
            jobs = result.2.jobs + jobs.filter { downloadedJobIDs.contains($0.id) && !remoteJobIDs.contains($0.id) }
            let neededBookIDs = Set(jobs.map(\.bookId))
            let remoteBookIDs = Set(result.3.books.map(\.id))
            books = result.3.books + books.filter { neededBookIDs.contains($0.id) && !remoteBookIDs.contains($0.id) }
            legacyRecordings = result.4.recordings; importedPronunciations = result.5.pronunciationRules
            try persist(); status = "Connected to your companion"
        } catch { status = "Companion unavailable · downloaded books stay ready"; if reportErrors { self.error = error.localizedDescription } }
    }
    func receiveBook(_ remote: RemoteBook, library: LibraryStore) async {
        guard let client, !receivingBook else { return }
        receivingBook = true; defer { receivingBook = false }
        do {
            let source = try await client.downloadBookSource(remote)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            var local = try await library.importBook(source)
            local.title = remote.title; local.author = remote.author; local.language = remote.language; local.companionBookID = remote.id
            library.update(local)
        } catch { self.error = error.localizedDescription }
    }
    func downloadLegacy(_ recording: LegacyRecording, localBook: LocalBook) async {
        guard let client, downloading == nil else { return }
        downloading = recording.id; defer { downloading = nil }
        do {
            let file = "Audio/" + SourceIdentity.hash(Data(recording.asset.id.utf8)) + ".wav"
            try await client.download(recording.asset, to: root.appendingPathComponent(file))
            downloads.removeAll { $0.id == recording.asset.id }
            downloads.append(DownloadRecord(localBookID: localBook.id, jobID: "legacy:" + recording.id, asset: recording.asset, file: file, segment: nil, legacyTitle: recording.title, legacyMapping: recording.mapping))
            try persist()
        } catch { self.error = error.localizedDescription }
    }
    func upload(_ local: LocalBook, library: LibraryStore) async throws -> RemoteBook {
        guard let client else { throw BookError.message("Pair your PC companion first.") }
        if let existing = books.first(where: { $0.sourceSha256 == local.sourceSHA256 }) { return existing }
        let filename = local.title.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_") + "." + library.file(local, original: true).pathExtension
        let remote = try await client.uploadBook(library.file(local, original: true), displayName: filename)
        books.removeAll { $0.id == remote.id }; books.append(remote)
        var updated = library.book(local.id) ?? local; updated.companionBookID = remote.id; library.update(updated)
        try persist(); return remote
    }
    func generate(book: RemoteBook, segments: [String], voice: RemoteVoice, rules: [PronunciationRule], announce: Bool, cast: [String: String]? = nil, narrationPlan: [NarrationSpan]? = nil, takeID: String? = nil) async throws {
        let request = GenerationRequest(requestId: UUID().uuidString.lowercased(), bookId: book.id, segmentIds: segments, engine: voice.engine, voiceId: voice.id, language: book.language, pronunciationRules: rules, announceChapters: announce, cast: cast, narrationPlan: narrationPlan, takeId: takeID)
        for existing in pendingRequests {
            var comparison = request
            comparison.requestId = existing.requestId
            if try CompanionClient.encoder.encode(comparison) == CompanionClient.encoder.encode(existing) {
                try await submit(existing)
                return
            }
        }
        pendingRequests.append(request); try persist()
        try await submit(request)
    }
    func fetchCast(_ bookID: String) async throws -> BookCast {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        return try await client.send("/v1/books/\(bookID)/cast")
    }
    func saveCast(_ cast: BookCast, bookID: String) async throws {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        let _: BookCast = try await client.send("/v1/books/\(bookID)/cast", method: "PUT", body: CompanionClient.encoder.encode(cast))
    }
    func analyze(_ bookID: String, allowHosted: Bool) async throws -> AnalysisJob {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        return try await client.send("/v1/books/\(bookID)/analyze", method: "POST", body: JSONSerialization.data(withJSONObject: ["allow_hosted": allowHosted]))
    }
    func analysis(_ id: String) async throws -> AnalysisJob {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        return try await client.send("/v1/analyses/\(id)")
    }
    func submit(_ request: GenerationRequest) async throws {
        guard let client else { throw BookError.message("Pair your PC companion first.") }
        let job: RemoteJob = try await client.send("/v1/jobs", method: "POST", body: CompanionClient.encoder.encode(request))
        jobs.removeAll { $0.id == job.id }; jobs.insert(job, at: 0)
        pendingRequests.removeAll { $0.requestId == request.requestId }
        try persist()
    }
    func jobAction(_ job: RemoteJob, _ action: String) async {
        do {
            guard let client, ["pause", "resume", "retry", "cancel"].contains(action) else { return }
            let updated: RemoteJob = try await client.send("/v1/jobs/\(job.id)/\(action)", method: "POST")
            jobs.removeAll { $0.id == job.id }; jobs.insert(updated, at: 0); try persist()
        } catch { self.error = error.localizedDescription }
    }
    func clone(name: String, engine: String, language: String, transcript: String, sample: URL) async throws {
        guard let client else { throw BookError.message("Pair your companion first.") }
        let scoped = sample.startAccessingSecurityScopedResource(); defer { if scoped { sample.stopAccessingSecurityScopedResource() } }
        let voice = try await client.cloneVoice(name: name, engine: engine, language: language, transcript: transcript, sample: sample)
        voices.append(voice)
    }
    func download(_ job: RemoteJob, localBook: LocalBook) async {
        guard let client, downloading == nil else { return }
        downloading = job.id; defer { downloading = nil }
        do {
            guard let remote = books.first(where: { $0.id == job.bookId }) else { throw BookError.message("Refresh the companion library before downloading.") }
            for asset in job.assets {
                if let existing = downloads.first(where: { $0.id == asset.id }), FileManager.default.fileExists(atPath: root.appendingPathComponent(existing.file).path) { continue }
                let file = "Audio/" + SourceIdentity.hash(Data(asset.id.utf8)) + (asset.mediaType.contains("mpeg") ? ".mp3" : ".wav")
                try await client.download(asset, to: root.appendingPathComponent(file))
                downloads.removeAll { $0.id == asset.id }
                downloads.append(DownloadRecord(localBookID: localBook.id, jobID: job.id, asset: asset, file: file, segment: remote.segments.first { $0.id == asset.segmentId }))
                try persist()
            }
        } catch { self.error = error.localizedDescription }
    }
    func play(_ record: DownloadRecord, library: LibraryStore, player: PlaybackController) {
        guard var book = library.book(record.localBookID) else { error = "Import the original book to read alongside this narration."; return }
        do {
            let offset = book.audioAssetID == record.id ? book.audioSeconds : 0
            let currentFollow = player.bookID == book.id ? player.onLocator : nil
            try player.play(url: root.appendingPathComponent(record.file), book: book, start: offset)
            if let legacyTitle = record.legacyTitle { player.title = legacyTitle; player.subtitle = "Legacy recording · no synchronized text" }
            var locationSaved = Date.distantPast
            player.onLocator = currentFollow ?? { [weak library] locator in
                if Date().timeIntervalSince(locationSaved) >= 3 { library?.saveLocation(record.localBookID, locator: locator); locationSaved = Date() }
            }
            book.audioAssetID = record.id; library.update(book)
            var lastSaved = -5.0
            player.onProgress = { [weak library, weak player] seconds in
                guard let library, var current = library.book(record.localBookID) else { return }
                if abs(seconds - lastSaved) >= 5 { current.audioAssetID = record.id; current.audioSeconds = seconds; library.update(current); lastSaved = seconds }
                guard let segment = record.segment, var locator = segment.locator.locator else { return }
                if let timing = record.asset.timings.first(where: { $0.start <= seconds && $0.end > seconds }), let range = SourceIdentity.scalarRange(timing.startOffset, timing.endOffset, in: segment.text) {
                    locator.text.highlight = String(segment.text[range])
                    locator.text.before = String(segment.text[..<range.lowerBound].suffix(60))
                    locator.text.after = String(segment.text[range.upperBound...].prefix(60))
                }
                player?.speechLocator = locator; player?.onLocator?(locator)
            }
            player.onFinished = { [weak self, weak library, weak player] in
                guard let self, let library, let player else { return }
                if var current = library.book(record.localBookID) { current.audioSeconds = 0; library.update(current) }
                let sequence = self.orderedDownloads(jobID: record.jobID)
                if let index = sequence.firstIndex(where: { $0.id == record.id }), index + 1 < sequence.count { self.play(sequence[index + 1], library: library, player: player) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func orderedDownloads(jobID: String) -> [DownloadRecord] {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return downloads.filter { $0.jobID == jobID } }
        return job.segmentIds.compactMap { id in downloads.first { $0.jobID == jobID && $0.asset.segmentId == id } }
    }
    func resumeRecord(jobID: String, library: LibraryStore) -> DownloadRecord? {
        let sequence = orderedDownloads(jobID: jobID)
        guard let first = sequence.first, let book = library.book(first.localBookID) else { return sequence.first }
        return sequence.first { $0.id == book.audioAssetID } ?? first
    }
    func takeDescription(jobID: String) -> String {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return "Available offline" }
        let voice = voices.first { $0.id == job.voiceId }?.name ?? "Narration"
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = job.createdAt.flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return voice + (date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
    }
    func removeDownloadedTake(_ jobID: String) throws {
        let removing = downloads.filter { $0.jobID == jobID }
        let previous = downloads
        downloads.removeAll { $0.jobID == jobID }
        do { try persist() } catch { downloads = previous; throw error }
        for record in removing { try? FileManager.default.removeItem(at: root.appendingPathComponent(record.file)) }
    }
    func export(_ job: RemoteJob, format: String) async throws -> URL {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        exporting = true; defer { exporting = false }
        let asset: AudioAsset = try await client.send("/v1/jobs/\(job.id)/export", method: "POST", body: JSONSerialization.data(withJSONObject: ["format": format]))
        let url = root.appendingPathComponent("Exports").appendingPathComponent("Audiobook-\(SourceIdentity.hash(Data(job.id.utf8)).prefix(12)).\(format == "project" ? "zip" : format)")
        try await client.download(asset, to: url)
        return url
    }
    func importProject(_ url: URL, library: LibraryStore) async throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let archive = try await Archive(url: url, accessMode: .read)
        let entries = try await archive.entries()
        guard entries.count < 100_000 else { throw BookError.message("This project has too many entries.") }
        var paths = Set<String>(); var expanded: UInt64 = 0
        for entry in entries {
            let path = entry.path
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.split(separator: "/").contains(".."), entry.type != .symlink, paths.insert(path).inserted else { throw BookError.message("This archive contains unsafe or duplicate paths.") }
            expanded += entry.uncompressedSize
            guard expanded <= 20 * 1024 * 1024 * 1024 else { throw BookError.message("This project exceeds the 20 GB import limit.") }
        }
        guard let manifest = entries.first(where: { $0.path == "project.json" }), manifest.uncompressedSize <= 100 * 1024 * 1024 else { throw BookError.message("This is not a Book Pocket production archive.") }
        var metadata = Data()
        _ = try await archive.extract(manifest) { metadata.append($0) }
        struct Project: Decodable { var formatVersion: Int; var book: RemoteBook; var job: RemoteJob }
        let project = try CompanionClient.decoder.decode(Project.self, from: metadata)
        guard project.formatVersion == 1, let original = entries.first(where: { ["source.epub", "source.txt"].contains($0.path) }) else { throw BookError.message("Unsupported project version or missing original book.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent(original.path)
        _ = try await archive.extract(original, to: source)
        guard SourceIdentity.hash(try Data(contentsOf: source, options: .mappedIfSafe)) == project.book.sourceSha256 else { throw BookError.message("The original book failed its checksum.") }
        var local = try await library.importBook(source)
        local.title = project.book.title; local.author = project.book.author; local.companionBookID = project.book.id; library.update(local)
        for asset in project.job.assets {
            guard let entry = entries.first(where: { $0.path == "audio/\(asset.id).wav" }), entry.uncompressedSize == UInt64(asset.bytes) else { throw BookError.message("The archive is missing expected audio.") }
            let extracted = folder.appendingPathComponent("audio.wav")
            if FileManager.default.fileExists(atPath: extracted.path) { try FileManager.default.removeItem(at: extracted) }
            _ = try await archive.extract(entry, to: extracted)
            let data = try Data(contentsOf: extracted, options: .mappedIfSafe)
            guard SourceIdentity.hash(data) == asset.sha256 else { throw BookError.message("An audio file failed its checksum.") }
            let file = "Audio/" + SourceIdentity.hash(Data(asset.id.utf8)) + ".wav"
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(file), options: .atomic)
            downloads.removeAll { $0.id == asset.id }; downloads.append(DownloadRecord(localBookID: local.id, jobID: project.job.id, asset: asset, file: file, segment: project.book.segments.first { $0.id == asset.segmentId }))
            try persist()
        }
        books.removeAll { $0.id == project.book.id }; books.append(project.book)
        jobs.removeAll { $0.id == project.job.id }; jobs.append(project.job)
        try persist()
    }
}
