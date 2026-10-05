import Foundation
import Observation
import ReadiumShared
import UIKit
import ReadiumZIPFoundation

enum CompanionConnectionState: Equatable {
    case notChecked, checking, connected, unavailable, disconnected
}

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
    var updatingConnection = false
    var exporting = false
    var receivingBook = false
    var paired: Bool { identity != nil && (client != nil || suspendedClient != nil) }
    private(set) var connectionPaused = false
    private(set) var connectionState: CompanionConnectionState = .notChecked
    private(set) var connectionError: String?
    private var client: CompanionClient?
    private var connectionRequiredMessage: String {
        connectionPaused ? "Connect your saved PC in the Connection tab, then try again." : "Pair your PC in the Connection tab first."
    }
    @ObservationIgnored private var suspendedClient: CompanionClient?
    @ObservationIgnored private var connectionEpoch = UUID()
    private var database: LibraryDatabase?
    private struct VerifiedFile {
        var size: Int
        var modified: Date
        var checksum: String
        var valid: Bool
    }
    @ObservationIgnored private var verifiedFiles: [String: VerifiedFile] = [:]
    @ObservationIgnored private var castDrafts: [String: CastDraft] = [:]
    @ObservationIgnored private var readerPlayers: [String: ReaderPlayerState] = [:]
    func readerPlayer(for bookID: String) -> ReaderPlayerState {
        if let existing = readerPlayers[bookID] { return existing }
        let value = ReaderPlayerState(); readerPlayers[bookID] = value; return value
    }
    func castDraft(for bookID: String) -> CastDraft {
        if let draft = castDrafts[bookID] { return draft }
        let draft = CastDraft(); castDrafts[bookID] = draft; return draft
    }
    let root: URL
    init(root: URL? = nil, client: CompanionClient? = nil) {
        self.root = root ?? URL.documentsDirectory.appendingPathComponent("Companion", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            database = try LibraryDatabase(url: self.root.appendingPathComponent("companion.sqlite"))
            identity = try database?.read("identity", as: CompanionIdentity.self)
            connectionPaused = try database?.read("connectionPaused", as: Bool.self) ?? false
            downloads = try database?.read("downloads", as: [DownloadRecord].self) ?? []
            books = try database?.read("books", as: [RemoteBook].self) ?? []
            jobs = try database?.read("jobs", as: [RemoteJob].self) ?? []
            pendingRequests = try database?.read("pendingRequests", as: [GenerationRequest].self) ?? []
            legacyRecordings = try database?.read("legacyRecordings", as: [LegacyRecording].self) ?? []
            importedPronunciations = try database?.read("pronunciations", as: [PronunciationRule].self) ?? []
            if let identity, let token = DeviceKeychain.read(account: identity.deviceID) { self.client = try CompanionClient(url: identity.url, fingerprint: identity.fingerprint, token: token) }
        } catch { self.error = error.localizedDescription }
        if let client { self.client = client }
        if connectionPaused {
            suspendedClient = self.client; self.client = nil; connectionState = .disconnected
        }
    }
    private func persist() throws {
        guard let database else { throw BookError.message("Companion storage is unavailable.") }
        try database.transaction {
            try database.write("identity", value: identity)
            try database.write("connectionPaused", value: connectionPaused)
            try database.write("downloads", value: downloads)
            try database.write("books", value: books)
            try database.write("jobs", value: jobs)
            try database.write("pendingRequests", value: pendingRequests)
            try database.write("legacyRecordings", value: legacyRecordings)
            try database.write("pronunciations", value: importedPronunciations)
        }
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
                    identity = CompanionIdentity(url: candidate.baseURL, fingerprint: candidate.fingerprint, deviceID: device)
                    client = candidate; suspendedClient = nil; connectionPaused = false
                    connectionEpoch = UUID()
                    connectionState = .notChecked; connectionError = nil
                    try persist(); status = "Paired securely"; await refresh(); return
                }
                if ["rejected", "expired"].contains(result.status) { throw BookError.message("Pairing \(result.status). Create a new code in your PC's Studio.") }
                try await Task.sleep(for: .seconds(2))
            }
            throw BookError.message("Pairing timed out. Create a new code in the PC Studio.")
        } catch is CancellationError { status = nil }
        catch { self.error = CompanionClient.narrationMessage(for: error); status = nil }
    }
    func updateConnection(url: URL, fingerprint: String?, configuration: URLSessionConfiguration? = nil) async throws {
        guard !updatingConnection, !pairing, let previous = identity, let oldClient = client ?? suspendedClient,
              let token = oldClient.token else { throw BookError.message("Pair this device before changing its companion address.") }
        updatingConnection = true
        defer { updatingConnection = false }
        let epoch = connectionEpoch
        let candidate = try CompanionClient(url: url, fingerprint: fingerprint, token: token, configuration: configuration)
        struct Health: Decodable { var apiVersion: String }
        let health: Health = try await candidate.send("/v1/health")
        guard health.apiVersion == "1" else { throw BookError.message("This companion uses an unsupported API version. Update PC Companion, then try again.") }
        struct Engines: Decodable { var engines: [RemoteEngine] }
        // This route requires the existing device token. A public health response
        // alone cannot establish that the new address reaches our paired PC.
        let _: Engines = try await candidate.send("/v1/engines")
        try Task.checkCancellation()
        guard connectionEpoch == epoch, (client ?? suspendedClient) === oldClient, identity?.deviceID == previous.deviceID,
              identity?.url == previous.url, identity?.fingerprint == previous.fingerprint else { throw CancellationError() }
        identity = CompanionIdentity(url: candidate.baseURL, fingerprint: candidate.fingerprint, deviceID: previous.deviceID)
        do { try persist() } catch { identity = previous; throw error }
        if connectionPaused { suspendedClient = candidate } else { client = candidate }
        connectionEpoch = UUID()
        connectionState = connectionPaused ? .disconnected : .connected; connectionError = nil
        error = nil; status = "Connected to your companion"
    }
    /// Disconnect locally without revoking the device token or cancelling PC work.
    func pauseConnection() throws {
        guard identity != nil, !connectionPaused else { return }
        connectionPaused = true
        do { try persist() } catch { connectionPaused = false; throw error }
        suspendedClient = client; client = nil
        connectionEpoch = UUID()
        connectionState = .disconnected; connectionError = nil; status = "Disconnected · pairing saved"
    }
    func resumeConnection() async {
        guard connectionPaused else { await checkConnection(); return }
        do {
            guard let candidate = suspendedClient else { throw BookError.message("Pair this device again to restore PC access.") }
            connectionPaused = false
            do { try persist() } catch { connectionPaused = true; throw error }
            client = candidate; suspendedClient = nil
            connectionEpoch = UUID()
            await checkConnection()
        } catch { connectionError = error.localizedDescription }
    }
    /// Forget is local and also works when the PC is offline. Downloads remain intact.
    func forgetConnection() throws {
        let previous = identity, wasPaused = connectionPaused
        identity = nil; connectionPaused = false
        do { try persist() } catch { identity = previous; connectionPaused = wasPaused; throw error }
        if let previous { DeviceKeychain.remove(account: previous.deviceID) }
        client = nil; suspendedClient = nil; engines = []; voices = []
        connectionEpoch = UUID()
        connectionState = .notChecked; connectionError = nil; status = nil; error = nil
    }
    /// A public health check alone is insufficient: the saved device must authenticate.
    func checkConnection() async {
        guard let client, connectionState != .checking else { return }
        let epoch = connectionEpoch, previousState = connectionState
        connectionState = .checking; connectionError = nil
        do {
            struct Health: Decodable { var apiVersion: String }
            struct Engines: Decodable { var engines: [RemoteEngine] }
            let health: Health = try await client.send("/v1/health")
            guard health.apiVersion == "1" else { throw BookError.message("Update your PC companion to connect.") }
            let _: Engines = try await client.send("/v1/engines")
            try Task.checkCancellation()
            guard self.client === client, connectionEpoch == epoch else { return }
            connectionState = .connected; status = "Connected to your companion"
        } catch {
            guard self.client === client, connectionEpoch == epoch else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                if connectionState == .checking { connectionState = previousState }
                return
            }
            connectionState = .unavailable; connectionError = CompanionClient.narrationMessage(for: error)
        }
    }
    func disconnect() async {
        do {
            if let client = client ?? suspendedClient { try await client.command("/v1/devices/current") }
            try forgetConnection()
        } catch { self.error = error.localizedDescription }
    }
    func refresh(reportErrors: Bool = true) async {
        guard let client, !refreshing else { return }
        let epoch = connectionEpoch
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
            guard self.client === client, connectionEpoch == epoch else { return }
            engines = result.0.engines; voices = result.1.voices
            let downloadedJobIDs = Set(downloads.map(\.jobID))
            let remoteJobIDs = Set(result.2.jobs.map(\.id))
            jobs = (result.2.jobs + jobs.filter { downloadedJobIDs.contains($0.id) && !remoteJobIDs.contains($0.id) }).map { job in
                var updated = job
                if updated.voiceName == nil { updated.voiceName = voices.first { $0.id == job.voiceId && $0.engine == job.engine }?.name }
                return updated
            }
            let neededBookIDs = Set(jobs.map(\.bookId))
            let remoteBookIDs = Set(result.3.books.map(\.id))
            books = result.3.books + books.filter { neededBookIDs.contains($0.id) && !remoteBookIDs.contains($0.id) }
            legacyRecordings = result.4.recordings; importedPronunciations = result.5.pronunciationRules
            try persist(); status = "Connected to your companion"; connectionState = .connected; connectionError = nil
        } catch {
            guard self.client === client, connectionEpoch == epoch else { return }
            status = "Companion unavailable · downloaded books stay ready"
            connectionState = .unavailable; connectionError = CompanionClient.narrationMessage(for: error)
            if reportErrors { self.error = connectionError }
        }
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
            downloads.removeAll { $0.jobID == "legacy:" + recording.id && $0.asset.id == recording.asset.id }
            downloads.append(DownloadRecord(localBookID: localBook.id, jobID: "legacy:" + recording.id, asset: recording.asset, file: file, segment: nil, legacyTitle: recording.title, legacyMapping: recording.mapping))
            try persist()
        } catch { self.error = error.localizedDescription }
    }
    func upload(_ local: LocalBook, library: LibraryStore) async throws -> RemoteBook {
        guard let client else { throw BookError.message(connectionRequiredMessage) }
        if let existing = books.first(where: { $0.sourceSha256 == local.sourceSHA256 }) {
            var updated = library.book(local.id) ?? local; updated.companionBookID = existing.id; library.update(updated)
            return existing
        }
        let filename = local.title.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_") + "." + library.file(local, original: true).pathExtension
        let remote = try await client.uploadBook(library.file(local, original: true), displayName: filename)
        books.removeAll { $0.id == remote.id }; books.append(remote)
        var updated = library.book(local.id) ?? local; updated.companionBookID = remote.id; library.update(updated)
        try persist(); return remote
    }
    @discardableResult func generate(book: RemoteBook, segments: [String], voice: RemoteVoice, rules: [PronunciationRule], announce: Bool, cast: [String: String]? = nil, narrationPlan: [NarrationSpan]? = nil, takeID: String? = nil, sourceRanges: [SourceRange]? = nil, narrationMode: String? = nil) async throws -> RemoteJob {
        let request = GenerationRequest(requestId: UUID().uuidString.lowercased(), bookId: book.id, segmentIds: segments, engine: voice.engine, voiceId: voice.id, language: book.language, pronunciationRules: rules, announceChapters: announce, cast: cast, narrationPlan: narrationPlan, takeId: takeID, sourceRanges: sourceRanges, narrationMode: narrationMode)
        for existing in pendingRequests {
            var comparison = request
            comparison.requestId = existing.requestId
            if try CompanionClient.encoder.encode(comparison) == CompanionClient.encoder.encode(existing) {
                return try await submit(existing)
            }
        }
        pendingRequests.append(request); try persist()
        return try await submit(request)
    }
    func requireSourceRanges() async throws {
        guard let client else { throw BookError.message(connectionRequiredMessage) }
        struct Health: Decodable { var capabilities: [String]? }
        let health: Health = try await client.send("/v1/health")
        guard health.capabilities?.contains("source_ranges") == true else { throw BookError.message("Update PC Companion to a version supporting exact source ranges, then reconnect. This PC cannot safely generate only the selected page.") }
    }
    func requireSourceRangeCast() async throws {
        guard let client else { throw BookError.message(connectionRequiredMessage) }
        struct Health: Decodable { var capabilities: [String]? }
        let health: Health = try await client.send("/v1/health")
        guard health.capabilities?.contains("source_ranges_cast") == true else {
            throw BookError.message("Update PC Companion to support the reader's narrator choices and exact Full cast selections, then refresh.")
        }
    }
    func refreshJob(_ id: String) async throws -> RemoteJob {
        guard let client else { throw BookError.message("Reconnect your paired PC to refresh this narration.") }
        let job: RemoteJob = try await client.send("/v1/jobs/\(id)")
        jobs.removeAll { $0.id == id }; jobs.insert(job, at: 0); try persist(); return job
    }
    func fetchCast(_ bookID: String) async throws -> BookCast {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        return try await client.send("/v1/books/\(bookID)/cast")
    }
    func saveCast(_ cast: BookCast, bookID: String) async throws {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        let _: BookCast = try await client.send("/v1/books/\(bookID)/cast", method: "PUT", body: CompanionClient.encoder.encode(cast))
    }
    func requireReliableAnalysis() async throws {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        struct Health: Decodable { var capabilities: [String]? }
        let health: Health = try await client.send("/v1/health")
        guard health.capabilities?.contains("analysis_request_id") == true else {
            throw BookError.message("Update PC Companion to a version supporting reliable analysis requests, then refresh. This version cannot safely recover an analysis after a lost connection.")
        }
    }
    func analyze(_ bookID: String, request: CastAnalysisRequest) async throws -> AnalysisJob {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        try await requireReliableAnalysis()
        return try await client.send("/v1/books/\(bookID)/analyze", method: "POST", body: CompanionClient.encoder.encode(request))
    }
    func analysis(_ id: String) async throws -> AnalysisJob {
        guard let client else { throw BookError.message("Connect to your companion first.") }
        return try await client.send("/v1/analyses/\(id)")
    }
    @discardableResult func submit(_ request: GenerationRequest) async throws -> RemoteJob {
        guard let client else { throw BookError.message(connectionRequiredMessage) }
        if request.sourceRanges?.isEmpty == false { try await requireSourceRanges() }
        if request.narrationMode != nil || (request.sourceRanges?.isEmpty == false && request.narrationPlan?.isEmpty == false) { try await requireSourceRangeCast() }
        let job: RemoteJob = try await client.send("/v1/jobs", method: "POST", body: CompanionClient.encoder.encode(request))
        if let ranges = request.sourceRanges, !ranges.isEmpty, job.sourceRanges != ranges { throw BookError.message("The PC did not confirm the exact source ranges. Update PC Companion before retrying this request.") }
        if let mode = request.narrationMode, job.narrationMode != mode { throw BookError.message("The PC did not confirm your narrator choice. Update PC Companion before retrying this request.") }
        if request.narrationMode != nil {
            guard job.bookId == request.bookId, job.engine == request.engine, job.voiceId == request.voiceId,
                  job.segmentIds == request.segmentIds, (job.narrationPlan ?? []) == (request.narrationPlan ?? []) else {
                throw BookError.message("The PC did not confirm the selected voices and passages. Refresh the companion before retrying this request.")
            }
        }
        jobs.removeAll { $0.id == job.id }; jobs.insert(job, at: 0)
        pendingRequests.removeAll { $0.requestId == request.requestId }
        try persist()
        return job
    }
    @discardableResult func jobAction(_ job: RemoteJob, _ action: String) async -> Bool {
        do {
            guard let client, ["pause", "resume", "retry", "cancel"].contains(action) else { return false }
            if job.sourceRanges?.isEmpty == false && ["resume", "retry"].contains(action) { try await requireSourceRanges() }
            if ["resume", "retry"].contains(action) && (job.narrationMode != nil || (job.sourceRanges?.isEmpty == false && job.narrationPlan?.isEmpty == false)) { try await requireSourceRangeCast() }
            let updated: RemoteJob = try await client.send("/v1/jobs/\(job.id)/\(action)", method: "POST")
            jobs.removeAll { $0.id == job.id }; jobs.insert(updated, at: 0); try persist()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func clone(name: String, engine: String, language: String, transcript: String, sample: URL) async throws {
        guard let client else { throw BookError.message(connectionRequiredMessage) }
        let scoped = sample.startAccessingSecurityScopedResource(); defer { if scoped { sample.stopAccessingSecurityScopedResource() } }
        let voice = try await client.cloneVoice(name: name, engine: engine, language: language, transcript: transcript, sample: sample)
        voices.append(voice)
    }
    @discardableResult func download(_ job: RemoteJob, localBook: LocalBook) async -> Bool {
        guard downloading == nil else { return false }
        downloading = job.id; defer { downloading = nil }
        error = nil
        do {
            guard let remote = books.first(where: { $0.id == job.bookId }) else { throw BookError.message("Refresh the companion library before downloading.") }
            try RangedAudioValidation.validate(job: job, book: remote)
            for asset in job.assets {
                let file = "Audio/" + SourceIdentity.hash(Data(asset.id.utf8)) + (asset.mediaType.contains("mpeg") ? ".mp3" : ".wav")
                verifiedFiles.removeValue(forKey: file)
                for record in downloads where record.asset.id == asset.id { verifiedFiles.removeValue(forKey: record.file) }
                if let cached = downloads.first(where: { $0.asset.id == asset.id && $0.asset.sha256 == asset.sha256 }),
                   let data = try? Data(contentsOf: root.appendingPathComponent(cached.file), options: .mappedIfSafe), data.count == asset.bytes, SourceIdentity.hash(data) == asset.sha256 {
                    if cached.file != file { try data.write(to: root.appendingPathComponent(file), options: .atomic) }
                } else {
                    guard let client else { throw BookError.message("Reconnect your PC and retry the download to restore the missing audio.") }
                    try await client.download(asset, to: root.appendingPathComponent(file))
                }
                let replaced = downloads.filter { $0.jobID == job.id && ($0.asset.id == asset.id || $0.asset.segmentId == asset.segmentId) }
                downloads.removeAll { $0.jobID == job.id && ($0.asset.id == asset.id || $0.asset.segmentId == asset.segmentId) }
                downloads.append(DownloadRecord(localBookID: localBook.id, jobID: job.id, asset: asset, file: file, segment: remote.segments.first { $0.id == asset.segmentId }))
                try persist()
                for old in replaced where !downloads.contains(where: { $0.file == old.file }) { try? FileManager.default.removeItem(at: root.appendingPathComponent(old.file)) }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func play(_ record: DownloadRecord, library: LibraryStore, player: PlaybackController, fromBeginning: Bool = false) {
        guard var book = library.book(record.localBookID) else {
            error = "Import the original book to read alongside this narration."; player.error = error; return
        }
        do {
            guard available(record, recheck: true) else {
                player.pause()
                throw BookError.message("This recording is missing, damaged, or no longer matches this take. Reconnect your PC and retry its download in Studio.")
            }
            let offset = !fromBeginning && (book.audioAssetID == record.id || book.audioAssetID == record.asset.id) ? book.audioSeconds : 0
            let currentFollow = player.bookID == book.id ? player.onLocator : nil
            try player.play(url: root.appendingPathComponent(record.file), book: book, start: offset)
            let remoteBookID = jobs.first(where: { $0.id == record.jobID })?.bookId
            player.chapterTitle = books.first(where: { $0.id == remoteBookID })?.chapters.first(where: { chapter in chapter.segments.contains { $0.id == record.asset.segmentId } })?.title ?? ""
            if let legacyTitle = record.legacyTitle { player.title = legacyTitle; player.subtitle = "Legacy recording · no synchronized text" }
            var locationSaved = Date.distantPast
            player.onLocator = currentFollow ?? { [weak library] locator in
                if Date().timeIntervalSince(locationSaved) >= 3 { library?.saveLocation(record.localBookID, locator: locator); locationSaved = Date() }
            }
            book.audioAssetID = record.id; book.audioSeconds = offset; library.update(book)
            var lastSaved = -5.0
            player.onProgress = { [weak library, weak player] seconds in
                guard let library, var current = library.book(record.localBookID) else { return }
                if abs(seconds - lastSaved) >= 5 { current.audioAssetID = record.id; current.audioSeconds = seconds; library.update(current); lastSaved = seconds }
                guard let segment = record.segment, var locator = segment.locator.locator else { return }
                if let start = record.asset.sourceStart, let end = record.asset.sourceEnd, let range = SourceIdentity.scalarRange(start, end, in: segment.text) {
                    locator.text.highlight = String(segment.text[range]); locator.text.before = String(segment.text[..<range.lowerBound].suffix(60)); locator.text.after = String(segment.text[range.upperBound...].prefix(60))
                }
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
                guard let job = self.jobs.first(where: { $0.id == record.jobID }),
                      let index = job.segmentIds.firstIndex(where: { $0 == record.asset.segmentId }), index + 1 < job.segmentIds.count else { return }
                let nextID = job.segmentIds[index + 1]
                guard let next = self.orderedDownloads(jobID: job.id).first(where: { $0.asset.segmentId == nextID }) else {
                    player.pause()
                    player.error = "The next passage is not available on this device. Reconnect your PC and download this take in Studio to continue without skipping text."
                    return
                }
                self.play(next, library: library, player: player)
            }
        } catch { self.error = error.localizedDescription; player.error = error.localizedDescription }
    }
    func orderedDownloads(jobID: String) -> [DownloadRecord] {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return downloads.filter { $0.jobID == jobID && available($0) } }
        return job.segmentIds.compactMap { id in
            guard let asset = job.assets.first(where: { $0.segmentId == id }) else { return nil }
            return downloads.first { $0.jobID == jobID && $0.asset.id == asset.id && available($0) }
        }
    }
    /// Cache hashes for unchanged files when listing takes; playback always rechecks.
    /// A persisted record alone is never evidence that its audio is still available.
    private func available(_ record: DownloadRecord, recheck: Bool = false) -> Bool {
        if let job = jobs.first(where: { $0.id == record.jobID }) {
            guard let asset = job.assets.first(where: { $0.id == record.asset.id }),
                  asset.sha256.lowercased() == record.asset.sha256.lowercased(), asset.bytes == record.asset.bytes,
                  asset.segmentId == record.asset.segmentId, asset.sourceStart == record.asset.sourceStart,
                  asset.sourceEnd == record.asset.sourceEnd else { return false }
        } else if !record.jobID.hasPrefix("legacy:") { return false }
        let url = root.appendingPathComponent(record.file)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size == record.asset.bytes, let modified = values.contentModificationDate else { return false }
        let checksum = record.asset.sha256.lowercased()
        if !recheck, let cached = verifiedFiles[record.file], cached.size == size,
           cached.modified == modified, cached.checksum == checksum { return cached.valid }
        let valid = (try? Data(contentsOf: url, options: .mappedIfSafe)).map { SourceIdentity.hash($0) == checksum } ?? false
        verifiedFiles[record.file] = VerifiedFile(size: size, modified: modified, checksum: checksum, valid: valid)
        return valid
    }
    func downloadedChapters(jobID: String) -> [DownloadedChapter] {
        guard let job = jobs.first(where: { $0.id == jobID }), let book = books.first(where: { $0.id == job.bookId }) else { return [] }
        let records = orderedDownloads(jobID: jobID).filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.file).path) }
        return book.chapters.compactMap { chapter in
            guard let first = records.first(where: { record in chapter.segments.contains { $0.id == record.asset.segmentId } }) else { return nil }
            return DownloadedChapter(id: chapter.id, title: chapter.title, firstRecord: first)
        }
    }
    /// The browser spans a book, but every choice remains an independent job.
    /// Playback sequencing continues to use orderedDownloads(jobID:) exclusively.
    func downloadedChapterGroups(for localBook: LocalBook) -> [DownloadedChapterGroup] {
        let matchingBooks = books.filter { $0.sourceSha256 == localBook.sourceSHA256 }
        let bookIDs = Set(matchingBooks.map(\.id))
        let eligibleJobs = jobs.filter { job in bookIDs.contains(job.bookId) && downloads.contains(where: { $0.jobID == job.id && $0.localBookID == localBook.id }) }
            .sorted { ($0.createdAt ?? "", $0.id) < ($1.createdAt ?? "", $1.id) }
        var groups: [DownloadedChapterGroup] = []
        for remote in matchingBooks {
            for chapter in remote.chapters {
                var takes: [DownloadedChapterTake] = []
                for (index, job) in eligibleJobs.enumerated() where job.bookId == remote.id {
                    let records = orderedDownloads(jobID: job.id).filter { record in
                        guard record.localBookID == localBook.id, record.legacyTitle == nil,
                              chapter.segments.contains(where: { $0.id == record.asset.segmentId }),
                              let asset = job.assets.first(where: { $0.id == record.asset.id }),
                              record.asset.sha256 == asset.sha256, record.asset.bytes == asset.bytes,
                              record.asset.segmentId == asset.segmentId,
                              record.asset.sourceStart == asset.sourceStart, record.asset.sourceEnd == asset.sourceEnd,
                              let size = try? root.appendingPathComponent(record.file).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
                        return size == asset.bytes
                    }
                    guard let first = records.first else { continue }
                    let complete = !chapter.segments.isEmpty && chapter.segments.allSatisfy { segment in
                        guard let record = records.first(where: { $0.asset.segmentId == segment.id }) else { return false }
                        guard (record.asset.sourceStart == nil) == (record.asset.sourceEnd == nil) else { return false }
                        let range = job.sourceRanges?.first { $0.segmentId == segment.id }
                        let start = record.asset.sourceStart ?? range?.startOffset ?? 0
                        let end = record.asset.sourceEnd ?? range?.endOffset ?? segment.text.unicodeScalars.count
                        return start == 0 && end == segment.text.unicodeScalars.count &&
                            (job.sourceRanges?.isEmpty != false || (range?.startOffset == 0 && range?.endOffset == segment.text.unicodeScalars.count))
                    }
                    let engine = engines.first(where: { $0.id == job.engine })?.name ?? job.engine
                    let voice = voices.first(where: { $0.id == job.voiceId })?.name ?? "Voice not saved"
                    let date = job.createdAt.flatMap { value -> Date? in
                        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
                    }
                    let detail = "Take \(index + 1) · \(voice) · \(engine)" + (date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    takes.append(.init(id: job.id + ":" + chapter.id, jobID: job.id, description: detail, scope: complete ? "Full chapter" : "Excerpt", recordIDs: records.map(\.id), firstRecord: first))
                }
                guard !takes.isEmpty else { continue }
                if let index = groups.firstIndex(where: { $0.id == chapter.id }) { groups[index].takes.append(contentsOf: takes) }
                else { groups.append(.init(id: chapter.id, title: chapter.title, takes: takes)) }
            }
        }
        return groups
    }
    func refreshNarrationInventory() async throws {
        guard let client else { throw BookError.message(connectionRequiredMessage) }
        struct Engines: Decodable { var engines: [RemoteEngine] }
        struct Voices: Decodable { var voices: [RemoteVoice] }
        struct Pronunciations: Decodable { var pronunciationRules: [PronunciationRule] }
        async let e: Engines = client.send("/v1/engines")
        async let v: Voices = client.send("/v1/voices")
        async let p: Pronunciations = client.send("/v1/pronunciations")
        let inventory = try await (e, v, p)
        engines = inventory.0.engines; voices = inventory.1.voices; importedPronunciations = inventory.2.pronunciationRules
        try persist()
    }
    func resumeRecord(jobID: String, library: LibraryStore) -> DownloadRecord? {
        let sequence = orderedDownloads(jobID: jobID)
        guard let first = sequence.first, let book = library.book(first.localBookID) else { return sequence.first }
        if let saved = downloads.first(where: { $0.jobID == jobID && ($0.id == book.audioAssetID || $0.asset.id == book.audioAssetID) }) {
            return sequence.first { $0.id == saved.id }
        }
        guard let job = jobs.first(where: { $0.id == jobID }) else { return first }
        return sequence.first { $0.asset.segmentId == job.segmentIds.first }
    }
    func playDownloadedTake(jobID: String, library: LibraryStore, player: PlaybackController) {
        guard let record = resumeRecord(jobID: jobID, library: library) else {
            player.pause()
            player.error = "The passage needed to resume this take is missing or damaged. Reconnect your PC and retry its download in Studio."
            return
        }
        play(record, library: library, player: player)
    }
    func takeDescription(jobID: String) -> String {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return "Available offline" }
        let voice = job.voiceName ?? voices.first { $0.id == job.voiceId }?.name ?? "Narration"
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = job.createdAt.flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return voice + (date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
    }
    func removeDownloadedTake(_ jobID: String) throws {
        let removing = downloads.filter { $0.jobID == jobID }
        let previous = downloads
        downloads.removeAll { $0.jobID == jobID }
        do { try persist() } catch { downloads = previous; throw error }
        for record in removing where !downloads.contains(where: { $0.file == record.file }) { try? FileManager.default.removeItem(at: root.appendingPathComponent(record.file)) }
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
        try ProjectImportValidation.validate(job: project.job, book: project.book)
        func validateIdentities() throws {
            let conflict = BookError.message("This project reuses an existing identity for different content or source passages. Export a fresh project from its original PC; your existing books and recordings have been kept.")
            for book in books where book.id == project.book.id {
                guard book.sourceSha256 == project.book.sourceSha256,
                      try CompanionClient.encoder.encode(book.chapters) == CompanionClient.encoder.encode(project.book.chapters) else { throw conflict }
            }
            guard !jobs.contains(where: { $0.id == project.job.id && $0.bookId != project.book.id }) else { throw conflict }
            for asset in project.job.assets {
                let existing = downloads.filter { $0.asset.id == asset.id }.map(\.asset) + jobs.flatMap(\.assets).filter { $0.id == asset.id }
                for previous in existing {
                    guard try ProjectImportValidation.sameAudioIdentity(previous, asset) else { throw conflict }
                }
            }
        }
        try validateIdentities()
        guard project.formatVersion == 1, let original = entries.first(where: { ["source.epub", "source.txt"].contains($0.path) }) else { throw BookError.message("Unsupported project version or missing original book.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent(original.path)
        _ = try await archive.extract(original, to: source)
        guard SourceIdentity.hash(try Data(contentsOf: source, options: .mappedIfSafe)) == project.book.sourceSha256 else { throw BookError.message("The original book failed its checksum.") }
        // Stage and verify the entire archive before publishing any library or
        // companion metadata. No partially validated recording becomes playable.
        var staged: [(asset: AudioAsset, url: URL, file: String)] = []
        for (index, asset) in project.job.assets.enumerated() {
            guard asset.bytes > 0, let entry = entries.first(where: { $0.path == "audio/\(asset.id).wav" }), entry.uncompressedSize == UInt64(asset.bytes) else { throw BookError.message("The archive is missing expected audio.") }
            let extracted = folder.appendingPathComponent("audio-\(index).wav")
            _ = try await archive.extract(entry, to: extracted)
            let data = try Data(contentsOf: extracted, options: .mappedIfSafe)
            let checksum = SourceIdentity.hash(data)
            guard checksum == asset.sha256.lowercased() else { throw BookError.message("An audio file failed its checksum.") }
            staged.append((asset, extracted, "Audio/" + checksum + ".wav"))
        }
        // Library import is independently durable and deduplicates by original
        // SHA. An interruption may leave a valid standalone book, never half a take.
        var local = try await library.importBook(source)
        // Async extraction/import allows other store operations to finish. Check
        // their latest state before the synchronous install-and-publish section.
        try validateIdentities()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        var installed: [URL] = []
        let previous = (books: books, jobs: jobs, downloads: downloads)
        do {
            for item in staged {
                let destination = root.appendingPathComponent(item.file)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard SourceIdentity.hash(try Data(contentsOf: destination, options: .mappedIfSafe)) == item.asset.sha256.lowercased() else {
                        throw BookError.message("An existing audio file is damaged. Restore its download before importing this project. No existing recording was overwritten.")
                    }
                } else {
                    // The destination is content-addressed; moving a verified
                    // staging file cannot overwrite another take's bytes.
                    try FileManager.default.moveItem(at: item.url, to: destination)
                    installed.append(destination)
                }
            }
            downloads.removeAll { $0.jobID == project.job.id }
            downloads += staged.map { item in DownloadRecord(localBookID: local.id, jobID: project.job.id, asset: item.asset, file: item.file, segment: project.book.segments.first { $0.id == item.asset.segmentId }) }
            books.removeAll { $0.id == project.book.id }; books.append(project.book)
            jobs.removeAll { $0.id == project.job.id }; jobs.append(project.job)
            try persist()
        } catch {
            books = previous.books; jobs = previous.jobs; downloads = previous.downloads
            for url in installed where !previous.downloads.contains(where: { root.appendingPathComponent($0.file) == url }) { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        // Migrate old asset-ID filenames only after the new metadata is durable.
        // Files still referenced by another take remain untouched.
        for record in previous.downloads where record.jobID == project.job.id && !downloads.contains(where: { $0.file == record.file }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(record.file))
            verifiedFiles.removeValue(forKey: record.file)
        }
        local.title = project.book.title; local.author = project.book.author; local.companionBookID = project.book.id; library.update(local)
    }
}
