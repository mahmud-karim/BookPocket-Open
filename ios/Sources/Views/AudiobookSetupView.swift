import SwiftUI
import ReadiumShared

struct AudiobookSetupView: View {
    enum Destination { case generation, saved, pronunciation }
    let request: AudiobookSetupRequest
    let reader: ReaderModel
    @Bindable var state: ReaderPlayerState
    var initialDestination: Destination = .generation
    /// Catalog-only override; it never changes the frozen generation snapshot.
    var selectedChapter: RemoteChapter? = nil
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showPairing = false
    @State private var showCast = false
    @State private var showReview = false
    @State private var showPronunciation = false
    @State private var removingRecording: ReaderAudioRecording?
    @State private var deleteFromPC = false
    private var job: RemoteJob? { companion.jobs.first { $0.id == state.selectedJobID } }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var detail: Detail?
    private enum Detail: Identifiable {
        case saved
        var id: String {
            "saved"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(currentChapter).font(.headline)
                    Text("\(request.mode.title) · \(request.scope.title)").accessibilityIdentifier("audiobook.setup.context")
                    if isCapturedChapter { generatedControls }
                    savedAudioButton
                    pronunciationAndHighlighting
                    if let error = state.attention { Text(error).foregroundStyle(.red) }
                    if state.needsCast { Button("Review dialogue") { showReview = true }.accessibilityIdentifier("reader.player.review") }
                    if state.mode == .cast { Button("Set up cast", systemImage: "person.2") { Task { await openCast() } }.frame(minHeight: 48).disabled(state.working).accessibilityIdentifier("reader.player.cast") }
                    if isCapturedChapter && state.snapshot != nil { Text(state.preview).font(.system(.body, design: .serif)).textSelection(.enabled).accessibilityIdentifier("reader.generation.preview") }
                }.padding(20)
            }.background(Obsidian.background)
                .navigationTitle("Manage audiobook").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("audiobook.setup.close") } }
                .sheet(item: $detail) { _ in
                    NavigationStack { savedAudio.navigationTitle("Saved audio").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
                    }
                    .alert(deleteFromPC ? "Delete this entire generated take from your PC and iPhone?" : "Remove this download from your iPhone?", isPresented: Binding(get: { removingRecording != nil }, set: { if !$0 { removingRecording = nil } })) {
                        Button(deleteFromPC ? "Delete generated take" : "Remove download", role: .destructive) { removeRecording() }.accessibilityIdentifier("reader.recording.confirm")
                        Button("Cancel", role: .cancel) { removingRecording = nil }.accessibilityIdentifier("reader.recording.cancel")
                    } message: { Text(deleteFromPC ? "All page or chapter assets in this take will be deleted. Your book and other takes are kept." : "Your PC copy stays available to download again.") }
                }
                .sheet(isPresented: $showPairing, onDismiss: { refresh() }) { PairingView() }
                .sheet(isPresented: $showCast, onDismiss: { refreshPreparation() }) { if let remote = state.remote { CastView(book: remote, relevantRanges: state.selection?.ranges) } }
                .sheet(isPresented: $showReview, onDismiss: { refreshPreparation() }) { if let remote = state.remote { CastView(book: remote, relevantRanges: state.selection?.ranges, autoReview: true) } }
                .sheet(isPresented: $showPronunciation) { PronunciationEditorView(language: reader.book?.language ?? "en", onRegenerate: isCapturedChapter ? { capture(request.scope) } : nil) }
                .task(id: (state.selectedJobID ?? "") + ":\(state.pollRevision)") {
                    guard let id = state.selectedJobID else { return }
                    while !Task.isCancelled {
                        guard let current = companion.jobs.first(where: { $0.id == id }), ["queued", "running"].contains(current.status) || ["queued", "running"].contains(current.alignmentStatus ?? "") else { return }
                        do { _ = try await companion.refreshJob(id); try await Task.sleep(for: .seconds(3)) }
                        catch { if !Task.isCancelled { state.error = CompanionClient.narrationMessage(for: error) }; return }
                    }
                }
        }.tint(Obsidian.accent).preferredColorScheme(.dark)
            .onAppear {
                state.requestGenerationChoice = false
                if initialDestination == .saved { detail = .saved }
                if initialDestination == .pronunciation { showPronunciation = true }
            }
            .onDisappear { state.invalidatePlaybackIntent() }
    }
    private var capturedHref: String { request.snapshot.hrefs[request.snapshot.current.resource] }
    private var isCapturedChapter: Bool {
        selectedChapter.map { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(capturedHref) } ?? true
    }
    private var currentChapter: String { selectedChapter?.title ?? request.chapterTitle }
    private var recordings: [ReaderAudioRecording] {
        guard let local = reader.book,
              let book = companion.books.first(where: { $0.sourceSha256 == local.sourceSHA256 }),
              local.id == request.bookID,
              let chapter = book.chapters.first(where: { candidate in
                  if let selectedChapter { return candidate.id == selectedChapter.id }
                  return ReaderSourceMapper.href(candidate.href) == ReaderSourceMapper.href(capturedHref)
              }) else { return [] }
        return ReaderAudioCatalog.recordings(book: book, chapter: chapter, mode: state.mode,
            jobs: companion.jobs, localBookID: local.id, downloads: companion.orderedDownloads)
    }
    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
    @ViewBuilder private var savedAudioButton: some View {
        if state.mode != .device {
            Button { detail = .saved } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved audio").font(dynamicTypeSize.isAccessibilitySize ? .system(size: 16, weight: .medium) : .subheadline.weight(.medium))
                        if !dynamicTypeSize.isAccessibilitySize { Text(savedSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 48).contentShape(.rect)
            }.buttonStyle(.plain).background(Obsidian.surface, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier("reader.player.saved")
                .accessibilityValue(savedSummary)
        }
    }
    private var savedSummary: String {
        let all = recordings
        let pages = all.filter { $0.scope == .page }.count
        let chapter = all.contains { $0.scope == .chapter }
        return "\(pages) page \(pages == 1 ? "clip" : "clips") · \(chapter ? "Chapter available" : "Chapter not generated")"
    }
    private var savedAudio: some View {
        let all = recordings
        let pages = all.filter { $0.scope == .page }, chapters = all.filter { $0.scope == .chapter }
        return List {
            Section { Text(currentChapter).font(.headline); Text(state.mode.title).foregroundStyle(.secondary) }
            if let error = state.attention { Section { Text(error).foregroundStyle(.red) } }
            Section("Page clips") {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, recording in recordingRow(recording, number: index + 1).listRowBackground(Obsidian.surface) }
                if pages.isEmpty { Text("No saved page clips in this chapter.").foregroundStyle(.secondary) }
            }
            Section("Full chapter") {
                ForEach(chapters) { recording in recordingRow(recording).listRowBackground(Obsidian.surface) }
                if chapters.isEmpty {
                    Text("Chapter not generated").foregroundStyle(.secondary)
                    if isCapturedChapter {
                        Button("Generate audio…") { detail = nil; capture(request.scope) }.accessibilityIdentifier("reader.saved.generate")
                    }
                }
            }
        }.scrollContentBackground(.hidden).accessibilityIdentifier("reader.saved.list")
    }
    private func recordingRow(_ recording: ReaderAudioRecording, number: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { selectRecording(recording) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.scope == .chapter ? "Full chapter" : "Page clip \(number)").font(.headline)
                    if recording.scope == .page { Text(recording.preview).font(.subheadline).lineLimit(2) }
                    Label("\(recording.offline ? "Ready offline" : "On PC") · \(Int(recording.duration) / 60):\(String(format: "%02d", Int(recording.duration) % 60))", systemImage: recording.offline ? "checkmark.circle.fill" : "cloud")
                        .font(.caption).foregroundStyle(recording.offline ? .green : .secondary)
                    if recording.scope == .page, let page = state.pageSelection, let book = state.remote,
                       ReaderTakeMatch.covers(recording.job, book: book, selection: page) {
                        Text("Covers current page").font(.caption).foregroundStyle(Obsidian.accent)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("reader.saved." + recording.id)
            if !recording.offline {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task {
                        guard !state.working, let local = reader.book else { return }
                        state.working = true; defer { state.working = false }
                        if !(await companion.download(recording.job, localBook: local)) { state.error = companion.error }
                        else if let book = state.remote,
                                ReaderTakeMatch.ready(recording.job, book: book, selection: recording.selection,
                                    records: companion.orderedDownloads(jobID: recording.id), localBookID: local.id),
                                state.selectedJobID == recording.id { state.readyIDs.insert(recording.id) }
                    }
                }.frame(minHeight: 44).disabled(state.working).accessibilityIdentifier("reader.saved.download." + recording.id)
            }
            Menu {
                if recording.offline { Button("Remove download", systemImage: "iphone.slash", role: .destructive) { deleteFromPC = false; removingRecording = recording }.accessibilityIdentifier("reader.saved.remove." + recording.id) }
                Button("Delete generated take", systemImage: "trash", role: .destructive) { deleteFromPC = true; removingRecording = recording }.accessibilityIdentifier("reader.saved.delete." + recording.id)
            } label: { Label("Manage recording", systemImage: "ellipsis.circle").frame(minHeight: 44) }.accessibilityIdentifier("reader.saved.manage." + recording.id)
        }
    }
    private func selectRecording(_ recording: ReaderAudioRecording) {
        guard !state.working, let local = reader.book,
              let book = companion.books.first(where: { $0.id == recording.job.bookId && $0.sourceSha256 == local.sourceSHA256 }),
              ReaderTakeMatch.mode(recording.job) == state.mode else { return }
        state.invalidatePlaybackIntent()
        if player.bookID == reader.bookID { player.pause() }
        state.snapshot = nil; state.selection = recording.selection; state.remote = book
        state.savedJobID = recording.scope == .page ? recording.id : nil
        state.playbackScope = recording.scope; state.selectedJobID = recording.id; state.candidates = [recording.job]
        state.readyIDs = recording.offline ? [recording.id] : []; state.error = nil; state.captureError = nil; state.showingSelection = false
        detail = nil
    }
    private func removeRecording() {
        guard let recording = removingRecording else { return }
        removingRecording = nil
        if deleteFromPC {
            Task {
                do { try await companion.deleteGeneratedTake(recording.id, library: library, player: player) }
                catch { state.error = error.localizedDescription }
            }
        } else {
            do {
                let removing = companion.downloads.filter { $0.jobID == recording.id }
                if let current = library.book(player.bookID ?? ""), removing.contains(where: { $0.id == current.audioAssetID || $0.asset.id == current.audioAssetID }) { player.stop() }
                try companion.removeDownloadedTake(recording.id); state.readyIDs.remove(recording.id)
            } catch { state.error = error.localizedDescription }
        }
    }
    @ViewBuilder private var pronunciationAndHighlighting: some View {
        Button("Pronunciation", systemImage: "text.bubble") { showPronunciation = true }.frame(minHeight: 48).accessibilityIdentifier("reader.player.pronunciation")
        if let job, state.mode != .device {
            let word = !job.assets.isEmpty && job.assets.allSatisfy { $0.alignment == "word" && !$0.timings.isEmpty }
            Text(word ? "Word highlighting" : "Passage timing · word highlighting unavailable").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("reader.player.timing")
            if ["queued", "running"].contains(job.alignmentStatus ?? "") { ProgressView("Preparing word highlighting…").accessibilityIdentifier("reader.alignment.progress") }
            else if !word {
                Button("Enable word highlighting", systemImage: "text.word.spacing") {
                    Task { do { _ = try await companion.enableWordHighlighting(job.id); state.pollRevision += 1 } catch { state.error = error.localizedDescription } }
                }.frame(minHeight: 48).accessibilityIdentifier("reader.alignment.enable")
            }
            if let error = job.alignmentError { Text(error).foregroundStyle(.red) }
        }
    }
    @ViewBuilder private var generatedControls: some View {
        if state.working { ProgressView(state.analysisProgress ?? "Preparing narration…").accessibilityIdentifier("reader.player.working") }
        if let job {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(job.status.capitalized) · \(job.completedSegments) of \(job.totalSegments) passages").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader.generation.status")
                if ["queued", "running", "paused"].contains(job.status) {
                    ProgressView(value: Double(job.completedSegments), total: Double(max(1, job.totalSegments)))
                    HStack {
                        Button(job.status == "paused" ? "Resume generation" : "Pause generation") { action(job.status == "paused" ? "resume" : "pause") }
                        Button("Cancel", role: .destructive) { action("cancel") }
                    }.buttonStyle(.bordered)
                    Text("Your PC keeps this job when you close the player.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                if ["failed", "cancelled"].contains(job.status) { Button("Retry generation") { action("retry") }.frame(minHeight: 48) }
                if job.status == "completed", !state.readyIDs.contains(job.id) {
                    Button("Download audio", systemImage: "arrow.down.circle") { Task { await downloadAndPlay(job) } }
                        .buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent).disabled(state.working)
                        .accessibilityIdentifier("reader.player.download")
                }
            }
        }
        if !state.candidates.isEmpty {
            Menu {
                ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, take in
                    Button("Take \(state.candidates.count - index) · \(take.createdAt ?? "Imported") · \(state.readyIDs.contains(take.id) ? "Offline" : take.status)") {
                        state.invalidatePlaybackIntent()
                        if player.bookID == reader.bookID { player.pause() }; state.selectedJobID = take.id; state.showingSelection = false; state.pollRevision += 1
                    }
                }
            } label: { Label(state.selectedJobID == nil ? "Choose a matching take" : "Change take", systemImage: "list.bullet").frame(minHeight: 48) }
            .accessibilityIdentifier("reader.player.takes")
        }
        if state.showingSelection, state.voice != nil, state.selection != nil {
            Button("Generate with \(state.mode.title)", systemImage: "waveform.badge.plus") { Task { await state.generate(companion: companion) } }
                .buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent).disabled(state.working)
                .accessibilityIdentifier("reader.generation.submit")
        }
        Button { capture(request.scope) } label: { Label("Generate \(request.scope == .page ? "page" : "chapter") audio", systemImage: "waveform.badge.plus").frame(minHeight: 48) }
            .buttonStyle(.bordered).disabled(state.working || reader.capturingScope || !reader.pageReady).accessibilityIdentifier("reader.player.generate")
        if !companion.paired { Button("Pair your PC", systemImage: "qrcode.viewfinder") { showPairing = true }.frame(minHeight: 48) }
        else { Button("Refresh connection & takes", systemImage: "arrow.clockwise") { refresh() }.font(.caption).frame(minHeight: 48).disabled(state.working) }
    }
    private func control(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 22)).frame(minWidth: 48, minHeight: 48).contentShape(.rect) }.accessibilityIdentifier("reader.player." + id)
    }
    private func refreshLocal() {
        guard let local = reader.book, local.id == request.bookID else { return }
        state.discover(snapshot: request.snapshot, local: local, companion: companion)
    }
    private func capture(_ scope: NarrationScope) {
        guard isCapturedChapter else { return }
        state.invalidatePlaybackIntent()
        Task {
            do {
                guard request.bookID == reader.bookID else { throw BookError.message("Open this book again to set up its audio.") }
                let snapshot = request.snapshot
                detail = nil
                await state.prepare(snapshot: snapshot, reader: reader, library: library, companion: companion)
                if state.voice != nil && state.selection != nil { await state.generate(companion: companion) }
            }
            catch { state.error = error.localizedDescription }
        }
    }
    private func refreshPreparation() {
        guard let snapshot = state.snapshot, state.showingSelection else { refreshLocal(); return }
        Task { await state.prepare(snapshot: snapshot, reader: reader, library: library, companion: companion) }
    }
    private func refresh() {
        Task { await companion.refresh(reportErrors: false); if state.showingSelection { refreshPreparation() } else { refreshLocal() } }
    }
    private func action(_ action: String) {
        guard let job else { return }
        Task { if await companion.jobAction(job, action) { state.error = nil; state.pollRevision += 1 } else { state.error = companion.error } }
    }
    private func downloadAndPlay(_ job: RemoteJob) async {
        guard let local = reader.book, let remote = state.remote, let selection = state.selection, !state.working else { return }
        let intent = state.playbackIntent(jobID: job.id, bookID: local.id, location: reader.location)
        await state.downloadWithIntent(intent, currentBookID: { reader.bookID }, currentLocation: { reader.location }, download: {
            guard await companion.download(job, localBook: local) else { state.error = companion.error ?? "Wait for the current download, then retry."; return false }
            let records = companion.orderedDownloads(jobID: job.id)
            guard ReaderTakeMatch.ready(job, book: remote, selection: selection, records: records, localBookID: local.id) else { state.error = "Some passages are missing. Reconnect your PC and retry the download."; return false }
            if state.mode == intent.mode, let current = state.selection,
               ReaderTakeMatch.ready(job, book: remote, selection: current, records: records, localBookID: local.id) { state.readyIDs.insert(job.id) }
            return true
        }, play: { state.selectedJobID = job.id; state.readyIDs.insert(job.id) })
    }
    private func openCast() async {
        guard !state.working else { return }
        if state.remote == nil, let book = reader.book {
            do { state.remote = try await companion.upload(book, library: library) } catch { state.error = CompanionClient.narrationMessage(for: error); return }
        }
        showCast = state.remote != nil
    }
}
