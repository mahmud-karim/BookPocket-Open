import Foundation
import Observation
import ReadiumShared

enum ReaderVoiceMode: String, CaseIterable, Identifiable {
    case device, kyon, cast
    var id: String { rawValue }
    var title: String { switch self { case .device: "On-device"; case .kyon: "Kyon"; case .cast: "Full cast" } }
    var wireMode: String { self == .cast ? "full_cast" : "single" }
}

struct ReaderCastPlan {
    var narrator: RemoteVoice
    var spans: [NarrationSpan]

    static func build(cast: BookCast, book: RemoteBook, ranges: [SourceRange], voices: [RemoteVoice], engines: [RemoteEngine]) throws -> Self {
        let setup = BookError.message("Set up your cast first: save a narrator voice, assign character voices, and review the selected dialogue in Cast Studio.")
        guard let narratorID = cast.characters.first(where: { $0.id == "narrator" })?.voiceId,
              let narrator = voices.first(where: { $0.id == narratorID }),
              engines.contains(where: { $0.id == narrator.engine && $0.available }) else { throw setup }
        guard !ranges.isEmpty, Set(ranges.map(\.segmentId)).count == ranges.count,
              Set(cast.characters.map(\.id)).count == cast.characters.count else { throw setup }
        var plan: [NarrationSpan] = []
        for range in ranges {
            guard let segment = book.segments.first(where: { $0.id == range.segmentId }),
                  SourceIdentity.scalarRange(range.startOffset, range.endOffset, in: segment.text) != nil else { throw setup }
            let assignments = cast.assignments.filter { $0.segmentId == range.segmentId && $0.startOffset < range.endOffset && $0.endOffset > range.startOffset }.sorted { $0.startOffset < $1.startOffset }
            var end = range.startOffset
            for row in assignments {
                guard row.reviewed, SourceIdentity.scalarRange(row.startOffset, row.endOffset, in: segment.text) != nil,
                      let character = cast.characters.first(where: { $0.id == row.characterId }) else { throw setup }
                let id = character.voiceId ?? narrator.id
                guard voices.contains(where: { $0.id == id && $0.engine == narrator.engine }) else { throw setup }
                let start = max(range.startOffset, row.startOffset), stop = min(range.endOffset, row.endOffset)
                guard start >= end, stop > start else { throw setup }
                plan.append(.init(segmentId: segment.id, startOffset: start, endOffset: stop, voiceId: id)); end = stop
            }
        }
        return Self(narrator: narrator, spans: plan)
    }
}

struct ReaderPlaybackIntent {
    let session: UUID
    let jobID: String
    let bookID: String
    let mode: ReaderVoiceMode
    let ranges: [SourceRange]
    let snapshotID: UUID?
    let location: Locator?
}

enum ReaderTakeMatch {
    static func mode(_ job: RemoteJob) -> ReaderVoiceMode? {
        let castEvidence = job.narrationPlan?.isEmpty == false || job.cast?.isEmpty == false || job.assets.contains(where: { $0.narrationMode == "full_cast" || $0.castSpans?.isEmpty == false })
        if job.narrationMode == "full_cast" { return job.assets.contains(where: { $0.narrationMode == "single" }) ? nil : .cast }
        if job.narrationMode == nil && castEvidence { return .cast }
        if castEvidence { return nil }
        // Legacy jobs without voice provenance are deliberately not called Kyon.
        if job.narrationMode == "single", ["omnivoice", "voicestudio"].contains(job.engine),
           job.voiceName?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Kyon") == .orderedSame { return .kyon }
        return nil
    }
    static func covers(_ job: RemoteJob, book: RemoteBook, selection: ReaderSourceSelection) -> Bool {
        guard job.bookId == book.id, !selection.ranges.isEmpty else { return false }
        return selection.ranges.allSatisfy { selected in
            guard job.segmentIds.contains(selected.segmentId), let source = book.segments.first(where: { $0.id == selected.segmentId }) else { return false }
            let range = job.sourceRanges?.first { $0.segmentId == selected.segmentId }
            return (range?.startOffset ?? 0) <= selected.startOffset && (range?.endOffset ?? source.text.unicodeScalars.count) >= selected.endOffset
        }
    }
    static func ready(_ job: RemoteJob, book: RemoteBook, selection: ReaderSourceSelection, records: [DownloadRecord], localBookID: String) -> Bool {
        guard covers(job, book: book, selection: selection), job.status == "completed",
              Set(job.segmentIds).count == job.segmentIds.count,
              Set(job.assets.map(\.id)).count == job.assets.count,
              job.assets.count == job.segmentIds.count,
              job.completedSegments == job.segmentIds.count, job.totalSegments == job.segmentIds.count,
              Set(job.assets.compactMap(\.segmentId)) == Set(job.segmentIds),
              records.count == job.segmentIds.count else { return false }
        return job.segmentIds.allSatisfy { id in
            guard let asset = job.assets.first(where: { $0.segmentId == id }) else { return false }
            return records.contains { $0.jobID == job.id && $0.localBookID == localBookID && $0.asset.id == asset.id && $0.asset.sha256 == asset.sha256 && $0.asset.bytes == asset.bytes }
        }
    }
}

/// Retained by CompanionStore per local book. In-flight work survives panel
/// dismissal; accepted jobs and uncertain requests use the existing SQLite store.
@MainActor @Observable final class ReaderPlayerState {
    var mode: ReaderVoiceMode = .device
    var playbackScope: NarrationScope = .page
    var savedJobID: String?
    var pageSelection: ReaderSourceSelection?
    var snapshot: ReaderScopeSnapshot?
    var selection: ReaderSourceSelection?
    var remote: RemoteBook?
    var candidates: [RemoteJob] = []
    var readyIDs: Set<String> = []
    var selectedJobID: String?
    var voice: RemoteVoice?
    var plan: [NarrationSpan] = []
    var working = false
    var error: String?
    // Capture failures belong to the visible source. A later exact capture can
    // recover them without hiding a generation, download, or playback failure.
    var captureError: String?
    var attention: String? { error ?? captureError }
    var needsCast = false
    var showingSelection = false
    var pollRevision = 0
    private var playbackSession = UUID()
    var requiresTakeSelection: Bool { selectedJobID == nil && candidates.contains { $0.status == "completed" } }

    func invalidatePlaybackIntent() { playbackSession = UUID() }
    func playbackIntent(jobID: String, bookID: String, location: Locator?) -> ReaderPlaybackIntent {
        .init(session: playbackSession, jobID: jobID, bookID: bookID, mode: mode,
              ranges: selection?.ranges ?? [], snapshotID: snapshot?.id, location: location)
    }
    /// A download remains useful after navigation/dismissal. Only its playback
    /// permission expires; completed files stay in the ordinary durable store.
    @discardableResult func downloadWithIntent(_ intent: ReaderPlaybackIntent,
        currentBookID: () -> String, currentLocation: () -> Locator?,
        download: () async -> Bool, play: () -> Void) async -> Bool {
        guard !working else { return false }
        working = true; defer { working = false }
        guard await download() else { return false }
        guard playbackSession == intent.session, selectedJobID == intent.jobID,
              mode == intent.mode, selection?.ranges == intent.ranges, snapshot?.id == intent.snapshotID,
              currentBookID() == intent.bookID, currentLocation() == intent.location else { return true }
        play()
        return true
    }

    var preview: String {
        if let selection { return selection.text }
        guard let snapshot, snapshot.scope == .page else { return "The chapter boundaries are captured. Connect your PC to verify the original source and preview the exact words." }
        return snapshot.documents[snapshot.hrefs[snapshot.current.resource]]?.blocks.flatMap { block in
            block.visible.compactMap { span -> String? in
                guard let range = SourceIdentity.scalarRange(span.start, span.end, in: block.text) else { return nil }
                return String(block.text[range])
            }
        }.joined(separator: "\n\n") ?? ""
    }
    func discover(snapshot: ReaderScopeSnapshot, local: LocalBook, companion: CompanionStore) {
        self.snapshot = snapshot; selection = nil; candidates = []; readyIDs = []; remote = nil
        guard let book = companion.books.first(where: { $0.sourceSha256 == local.sourceSHA256 }),
              let selection = try? ReaderSourceMapper.resolve(snapshot, book: book) else { selectedJobID = nil; return }
        remote = book; self.selection = selection; captureError = nil
        pageSelection = snapshot.scope == .page ? selection : nil
        // An explicitly selected saved clip remains identifiable after reflow.
        // Chapter navigation and narrator changes cannot inherit that selection.
        if let saved = companion.jobs.first(where: { $0.id == savedJobID }),
           ReaderTakeMatch.mode(saved) == mode, saved.status == "completed",
           (try? RangedAudioValidation.validate(job: saved, book: book)) != nil,
           let chapter = book.chapters.first(where: { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(snapshot.hrefs[snapshot.current.resource]) }),
           let savedSelection = ReaderAudioCatalog.selection(job: saved, book: book, chapter: chapter) {
            self.selection = savedSelection; candidates = [saved]; selectedJobID = saved.id
            if ReaderTakeMatch.ready(saved, book: book, selection: savedSelection, records: companion.orderedDownloads(jobID: saved.id), localBookID: local.id) { readyIDs.insert(saved.id) }
            return
        }
        savedJobID = nil
        candidates = companion.jobs.filter { ReaderTakeMatch.mode($0) == mode && ReaderTakeMatch.covers($0, book: book, selection: selection) }
            .sorted { ($0.createdAt ?? "", $0.id) > ($1.createdAt ?? "", $1.id) }
        for job in candidates {
            if (try? RangedAudioValidation.validate(job: job, book: book)) != nil,
               ReaderTakeMatch.ready(job, book: book, selection: selection, records: companion.orderedDownloads(jobID: job.id), localBookID: local.id) { readyIDs.insert(job.id) }
        }
        // Preserve an explicit take; never silently select another alternate.
        if !candidates.contains(where: { $0.id == selectedJobID }) { selectedJobID = candidates.count == 1 ? candidates.first?.id : nil }
    }
    func prepare(snapshot: ReaderScopeSnapshot, reader: ReaderModel, library: LibraryStore, companion: CompanionStore) async {
        guard !working else { return }
        savedJobID = nil; playbackScope = snapshot.scope
        self.snapshot = snapshot; showingSelection = true; voice = nil; selection = nil; selectedJobID = nil; candidates = []; readyIDs = []; plan = []; error = nil; needsCast = false
        guard companion.paired, let local = reader.book else { return }
        working = true; defer { working = false }
        do {
            try await companion.requireSourceRanges()
            try await companion.requireSourceRangeCast()
            try await companion.refreshNarrationInventory()
            let book = try await companion.upload(local, library: library)
            remote = book; selection = try ReaderSourceMapper.resolve(snapshot, book: book); captureError = nil
            guard let selection else { return }
            if mode == .cast {
                guard !companion.castDraft(for: book.id).dirty, !companion.castDraft(for: book.id).busy else {
                    throw BookError.message("Finish reviewing and save your cast before generating. Open Set up cast to keep your latest edits.")
                }
                let saved = try await companion.fetchCast(book.id)
                let castPlan = try ReaderCastPlan.build(cast: saved, book: book, ranges: selection.ranges, voices: companion.voices, engines: companion.engines)
                voice = castPlan.narrator; plan = castPlan.spans
            } else { voice = try ReaderNarrator.kyon(voices: companion.voices, engines: companion.engines); plan = [] }
        } catch { self.error = CompanionClient.narrationMessage(for: error); needsCast = mode == .cast && remote != nil }
    }
    func generate(companion: CompanionStore) async {
        guard !working, let remote, let selection, let voice else { return }
        working = true; error = nil; defer { working = false }
        do {
            let job = try await companion.generate(book: remote, segments: selection.ranges.map(\.segmentId), voice: voice,
                rules: companion.importedPronunciations, announce: false, narrationPlan: mode == .cast ? plan : nil,
                sourceRanges: selection.ranges, narrationMode: mode.wireMode)
            selectedJobID = job.id; candidates = [job]; showingSelection = false; pollRevision += 1
        } catch { self.error = CompanionClient.narrationMessage(for: error) }
    }
}
