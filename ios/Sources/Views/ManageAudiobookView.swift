import SwiftUI

/// Setup is deliberately separate from Read aloud. The initial page snapshot
/// remains immutable even when chapter setup or reader pagination changes.
struct ManageAudiobookView: View {
    let request: AudiobookSetupRequest
    let reader: ReaderModel
    @Bindable var state: ReaderPlayerState
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var book: RemoteBook?
    @State private var chapterID = ""
    @State private var mode: ReaderVoiceMode = .kyon
    @State private var statuses: [ChapterAnalysisStatus] = []
    @State private var review: CastReviewInventory?
    @State private var loading = false
    @State private var error: String?
    @State private var consent = false
    @State private var destination: Destination?
    @State private var action: Task<Void, Never>?
    @State private var pairing = false
    @State private var generateScope = false
    @State private var generatedID: String?
    private enum Destination: String, Identifiable {
        case characters, review, pronunciation, generation, recordings
        var id: String { rawValue }
    }
    private var chapter: RemoteChapter? { book?.chapters.first { $0.id == chapterID } }
    private var capturedContext: String {
        if let book, let original = try? ReaderSourceMapper.resolve(request.snapshot, book: book) {
            return "\(request.scope.title) · \(original.text)"
        }
        // Offline setup can describe the reader's actual frozen page without
        // claiming that the PC has verified its canonical generation ranges.
        let snapshot = request.snapshot
        guard request.scope == .page, snapshot.hrefs.indices.contains(snapshot.current.resource),
              let document = snapshot.documents[snapshot.hrefs[snapshot.current.resource]] else {
            return "\(request.scope.title) · Original source unavailable"
        }
        let words = document.blocks.flatMap { block in
            block.visible.compactMap { span -> String? in
                guard let range = SourceIdentity.scalarRange(span.start, span.end, in: block.text) else { return nil }
                return String(block.text[range])
            }
        }.joined(separator: "\n\n")
        return words.isEmpty ? "\(request.scope.title) · Original source unavailable" : "\(request.scope.title) · \(words) · Awaiting PC source verification"
    }
    private var ranges: [SourceRange] { chapter?.segments.map { .init(segmentId: $0.id, startOffset: 0, endOffset: $0.text.unicodeScalars.count) } ?? [] }
    private var draft: CastDraft? { book.map { companion.castDraft(for: $0.id) } }
    private var summary: ManageAudiobookSummary? {
        guard let chapter, let draft, let review else { return nil }
        return .init(chapter: chapter, cast: draft.value, voices: companion.voices, engines: companion.engines, review: review, statuses: statuses)
    }
    private var selectedAnalysis: AnalysisJob? {
        guard let job = draft?.analysis else { return nil }
        return job.chapterIds == nil || job.chapterIds?.contains(chapterID) == true ? job : nil
    }
    private var analyzing: Bool {
        guard mode == .cast else { return false }
        let pendingHere = draft?.pendingAnalysisRequest.map { $0.chapterIds == nil || $0.chapterIds?.contains(chapterID) == true } == true
        return selectedAnalysis.map { ["queued", "running"].contains($0.status) } == true ||
            (draft?.busy == true && (selectedAnalysis != nil || pendingHere))
    }
    private var recordings: [ReaderAudioRecording] {
        guard let book, let chapter, let local = reader.book else { return [] }
        return ReaderAudioCatalog.recordings(book: book, chapter: chapter, mode: mode, jobs: companion.jobs,
            localBookID: local.id, downloads: companion.orderedDownloads)
    }
    private var pageCount: Int { recordings.filter { $0.scope == .page }.count }
    private var chapterRecordings: [ReaderAudioRecording] { recordings.filter { $0.scope == .chapter } }
    private var pageAvailable: Bool {
        guard let chapter, request.snapshot.hrefs.indices.contains(request.snapshot.current.resource) else { return false }
        return ReaderSourceMapper.href(chapter.href) == ReaderSourceMapper.href(request.snapshot.hrefs[request.snapshot.current.resource])
    }
    private var capturedPageReady: Bool {
        guard mode == .cast, request.scope == .page, pageAvailable,
              summary.map({ $0.missingVoiceCount > 0 || $0.pendingReviewCount > 0 }) == true,
              let book, let local = reader.book, let draft, let review,
              request.bookID == local.id, !draft.dirty, !draft.busy else { return false }
        return (try? ManageAudiobookSource.page(snapshot: request.snapshot, book: book, chapterID: chapterID,
            localSHA256: local.sourceSHA256, cast: draft.saved, voices: companion.voices,
            engines: companion.engines, review: review, statuses: statuses)) != nil
    }
    private var generationJob: RemoteJob? {
        guard let chapter, let book else { return nil }
        let IDs = Set(chapter.segments.map(\.id))
        return companion.jobs.first { job in
            (job.id == generatedID || job.id == state.selectedJobID) && job.bookId == book.id &&
                ReaderTakeMatch.mode(job) == mode && !job.segmentIds.isEmpty && job.segmentIds.allSatisfy { IDs.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    bookHeader
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Narration").font(.headline)
                        narrationPicker
                        chapterPicker
                    }
                    if mode == .cast { analysisCard }
                    if loading { ProgressView("Loading audiobook setup…") }
                    if !companion.paired {
                        Button("Connect your PC", systemImage: "desktopcomputer") { pairing = true }.buttonStyle(.borderedProminent)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).accessibilityIdentifier("manage.error")
                        Button("Refresh connection & setup", systemImage: "arrow.clockwise") { Task { await load() } }.accessibilityIdentifier("manage.refresh")
                    }
                    if mode == .cast {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Setup").font(.headline)
                            VStack(spacing: 0) {
                                row("Characters & voices", icon: "person.2", detail: summary.map { $0.needsAnalysis ? "Analyze chapter first" : $0.missingVoiceCount == 0 ? "Voices ready" : "\($0.missingVoiceCount) need voices" } ?? "Not checked", id: "manage.characters") { destination = .characters }
                                Divider().padding(.leading, 46)
                                row("Speaker review", icon: "text.bubble", detail: summary.map { $0.needsAnalysis ? "Analyze chapter first" : $0.pendingReviewCount == 0 ? "No lines to check" : "\($0.pendingReviewCount) lines to check" } ?? "Not checked", id: "manage.review") { destination = .review }
                                Divider().padding(.leading, 46)
                                pronunciationRow
                            }.background(Obsidian.surface, in: .rect(cornerRadius: 14))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Setup").font(.headline)
                            Text("Kyon reads every line with one voice. Chapter analysis isn't needed.").font(.callout).foregroundStyle(.secondary)
                            pronunciationRow.background(Obsidian.surface, in: .rect(cornerRadius: 14))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Audio").font(.headline)
                        VStack(spacing: 0) {
                            row("Page recordings", icon: "doc.text", detail: book == nil ? "Not checked" : "\(pageCount) saved", id: "manage.pages") { prepareRecordings() }
                            Divider().padding(.leading, 46)
                            row("Chapter recording", icon: "waveform", detail: book == nil ? "Not checked" : chapterRecordings.isEmpty ? "Not generated" : "\(chapterRecordings.count) saved", id: "manage.chapterRecording") { prepareRecordings() }
                        }.background(Obsidian.surface, in: .rect(cornerRadius: 14))
                        Text("Saved recordings are kept when you change voices or analyze again.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let job = generationJob { generationCard(job) }
                    mainAction
                }.padding(20)
            }.background(Obsidian.background).accessibilityIdentifier("manage.surface")
                .navigationTitle("Manage audiobook").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back to book").accessibilityIdentifier("manage.close") }
                }
                .sheet(item: $destination, onDismiss: { Task { await refreshMetadata(); beginRecovery() } }) { destination in
                    child(destination)
                }
                .sheet(isPresented: $pairing, onDismiss: { Task { await load() } }) { PairingView() }
                .alert("Analyze with Google?", isPresented: $consent) {
                    Button("Analyze chapter") { startAnalysis() }.accessibilityIdentifier("manage.analysis.consent.accept")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Google receives this chapter's text to suggest characters and speakers. Your saved voice choices and speaker corrections are kept. Only this selected chapter is analyzed.")
                }
                .confirmationDialog("Generate audio", isPresented: $generateScope, titleVisibility: .visible) {
                    if pageAvailable { Button("Captured page") { generate(.page) }.accessibilityIdentifier("manage.generate.page") }
                    Button("Selected chapter") { generate(.chapter) }.accessibilityIdentifier("manage.generate.chapter")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(pageAvailable ? "The page uses the exact words captured when you opened setup. The chapter includes the selected chapter's original text." : "Open this chapter in the reader to select a page. You can generate the complete selected chapter here.")
                }
                .task { mode = request.mode == .cast ? .cast : .kyon; await load() }
                .onChange(of: chapterID) { beginRecovery() }
                .onDisappear {
                    // Cancelling phone polling never cancels the accepted PC job.
                    // Its per-book draft or chapter-status ID resumes on return.
                    if destination == nil && !pairing { action?.cancel(); draft?.cancel() }
                }
        }.tint(Obsidian.accent).preferredColorScheme(.dark)
    }
    private var bookHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            if let local = reader.book {
                BookCover(book: local, url: library.cover(local)).frame(width: 54, height: 80)
            } else { Image(systemName: "book").font(.title).foregroundStyle(Obsidian.accent).frame(width: 54, height: 80).background(Obsidian.surface, in: .rect(cornerRadius: 8)) }
            VStack(alignment: .leading, spacing: 5) {
                Text(reader.book?.title ?? book?.title ?? "Audiobook").font(.system(.headline, design: .serif)).lineLimit(3)
                Text(reader.book?.author ?? book?.author ?? "").font(.subheadline).foregroundStyle(.secondary)
                Text("Set up voices, then generate your audio.").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("manage.book").accessibilityValue(capturedContext)
    }
    private var narrationPicker: some View {
        HStack(spacing: 3) {
            ForEach([ReaderVoiceMode.kyon, .cast]) { item in
                Button { mode = item } label: {
                    Text(item.title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(mode == item ? Obsidian.accent : Obsidian.surface, in: .rect(cornerRadius: 9))
                        .foregroundStyle(mode == item ? Obsidian.onAccent : .primary)
                        .contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("manage.narration." + item.rawValue)
                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                    .disabled(state.working)
            }
        }.padding(3).background(Obsidian.surface, in: .rect(cornerRadius: 12))
    }
    private var chapterPicker: some View {
        Menu {
            ForEach(book?.chapters ?? []) { item in
                Button { chapterID = item.id } label: {
                    if item.id == chapterID { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
        } label: {
            HStack { Image(systemName: "book").font(.title3); Text(chapter?.title ?? request.chapterTitle).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.down").font(.caption) }
                .padding(14).frame(minHeight: 48).background(Obsidian.surface, in: .rect(cornerRadius: 12))
        }.disabled(book == nil || state.working).accessibilityIdentifier("manage.chapter").accessibilityValue(chapter?.title ?? request.chapterTitle)
    }
    @ViewBuilder private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = selectedAnalysis {
                let progress = ManageAnalysisProgress(job: job, mergingResults: draft?.mergingResults == true || (job.status == "completed" && draft?.busy == true))
                HStack {
                    if analyzing { ProgressView() } else { Image(systemName: progress.failed ? "exclamationmark.circle" : "checkmark.circle.fill").foregroundStyle(Obsidian.accent) }
                    Text(progress.stage).font(.headline).accessibilityIdentifier("manage.analysis.stage")
                }
                if analyzing, let title = job.currentChapterTitle { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).tint(Obsidian.accent).accessibilityIdentifier("manage.analysis.progress")
                    HStack { Text(progress.count).accessibilityIdentifier("manage.analysis.count"); Spacer(); Text("\(Int(fraction * 100))%").monospacedDigit().accessibilityIdentifier("manage.analysis.percent") }.font(.caption).foregroundStyle(.secondary)
                } else { ProgressView(progress.count).accessibilityIdentifier("manage.analysis.progress") }
                if analyzing {
                    Text("You can keep reading while this runs.").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        analysisStep("Read chapter text", index: 0, current: progress.step)
                        analysisStep("Identify speakers", index: 1, current: progress.step)
                        analysisStep("Save cast suggestions", index: 2, current: progress.step)
                    }.padding(.top, 4)
                }
                if let message = job.error { Text(message).font(.callout).foregroundStyle(.red) }
                ForEach(Array((job.warnings ?? []).enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundStyle(.secondary) }
                if !analyzing {
                    Button(progress.failed ? "Retry analysis" : "Reanalyze chapter") { consent = true }
                        .accessibilityIdentifier(progress.failed ? "manage.analysis.retry" : "manage.analysis.start")
                }
            } else {
                Text("Chapter analysis").font(.headline)
                if analyzing {
                    ProgressView("Waiting for your PC to confirm analysis…").accessibilityIdentifier("manage.analysis.progress")
                    Text("You can keep reading while this runs.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Find characters and suggest who speaks each line.").font(.callout).foregroundStyle(.secondary)
                    Button { consent = true } label: { Label("Analyze chapter", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent).disabled(book == nil || loading || draft?.busy == true)
                        .accessibilityIdentifier("manage.analysis.start")
                }
                Text("Your saved voice choices are kept.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            if draft?.canResumeAnalysis == true {
                Button("Refresh analysis progress", systemImage: "arrow.clockwise") { beginRecovery() }.accessibilityIdentifier("manage.analysis.resume")
            }
            if let message = draft?.error { Text(message).font(.callout).foregroundStyle(.red) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Obsidian.surface, in: .rect(cornerRadius: 14))
    }
    private func analysisStep(_ title: String, index: Int, current: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "circle.dotted" : "circle")
                .foregroundStyle(index <= current ? Obsidian.accent : .secondary)
            Text(title).font(.subheadline)
        }
    }
    private var pronunciationRow: some View {
        row("Pronunciation", icon: "textformat", detail: "\(companion.narrationPronunciations.count) corrections", id: "manage.pronunciation") { destination = .pronunciation }
    }
    private func generationCard(_ job: RemoteJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(job.status.capitalized) · \(job.completedSegments) of \(job.totalSegments) passages").font(.subheadline).accessibilityIdentifier("manage.generation.status")
            if ["queued", "running", "paused"].contains(job.status) {
                ProgressView(value: Double(max(0, job.completedSegments)), total: Double(max(1, job.totalSegments))).tint(Obsidian.accent)
                HStack {
                    Button(job.status == "paused" ? "Resume" : "Pause") { generationAction(job, job.status == "paused" ? "resume" : "pause") }
                    Button("Cancel", role: .destructive) { generationAction(job, "cancel") }
                }.buttonStyle(.bordered)
                Text("Your PC keeps generating when you return to reading.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = job.error { Text(message).foregroundStyle(.red).font(.caption) }
            if ["failed", "cancelled"].contains(job.status) { Button("Retry generation") { generationAction(job, "retry") } }
            if job.status == "completed" {
                Button("Download audio", systemImage: "arrow.down.circle") {
                    Task { guard let local = reader.book else { return }; if !(await companion.download(job, localBook: local)) { error = companion.error } }
                }.accessibilityIdentifier("manage.generation.download")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Obsidian.surface, in: .rect(cornerRadius: 14))
            .task(id: job.id + ":\(state.pollRevision)") {
                while !Task.isCancelled {
                    guard let current = companion.jobs.first(where: { $0.id == job.id }), ["queued", "running"].contains(current.status) else { return }
                    do { _ = try await companion.refreshJob(job.id); try await Task.sleep(for: .seconds(3)) }
                    catch { if !Task.isCancelled { self.error = CompanionClient.narrationMessage(for: error) }; return }
                }
            }
    }
    private func generationAction(_ job: RemoteJob, _ operation: String) {
        Task { if await companion.jobAction(job, operation) { state.pollRevision += 1 } else { error = companion.error } }
    }
    private func row(_ title: String, icon: String, detail: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 24)
                Text(title).font(.subheadline)
                Spacer(minLength: 8)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 14).frame(minHeight: 50).contentShape(.rect)
        }.buttonStyle(.plain).disabled(book == nil && id != "manage.pronunciation").accessibilityIdentifier(id).accessibilityValue(detail)
    }
    private var mainAction: some View {
        Button {
            if analyzing { dismiss() }
            else if !companion.paired { pairing = true }
            else if mode == .cast, draft?.dirty == true { action = Task { await saveDraft() } }
            else if mode == .cast, summary?.needsAnalysis == true { consent = true }
            else if capturedPageReady { generate(.page) }
            else if mode == .cast, summary?.missingVoiceCount ?? 0 > 0 { destination = .characters }
            else if mode == .cast, summary?.pendingReviewCount ?? 0 > 0 { destination = .review }
            else { generateScope = true }
        } label: {
            Text(mainTitle).font(.headline).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent).accessibilityIdentifier("manage.main")
            .disabled(loading || state.working || (book == nil && companion.paired) ||
                      (mode == .cast && draft?.busy == true && !analyzing) ||
                      (mode == .cast && summary == nil && !analyzing && companion.paired))
            .padding(.top, 8)
    }
    private var mainTitle: String {
        if analyzing { return "Keep reading" }
        if !companion.paired { return "Connect your PC" }
        if mode == .cast {
            if draft?.dirty == true { return "Save cast changes" }
            if summary?.needsAnalysis == true { return "Analyze chapter" }
            if capturedPageReady { return "Generate page audio" }
            if summary?.missingVoiceCount ?? 0 > 0 { return "Choose character voices" }
            if summary?.pendingReviewCount ?? 0 > 0 { return "Review speakers" }
        }
        return "Generate audio"
    }
    @ViewBuilder private func child(_ destination: Destination) -> some View {
        switch destination {
        case .characters:
            if let book { CastView(book: book, relevantRanges: ranges, section: .characters) }
        case .review:
            if let book, let draft, let review, let issue = CastReview.pending(review, ranges: ranges).first {
                CastReviewView(book: book, relevantRanges: ranges, draft: draft, inventory: review, issue: issue)
            } else {
                NavigationStack { ContentUnavailableView(summary?.needsAnalysis == true ? "Analyze chapter first" : "No lines to check", systemImage: summary?.needsAnalysis == true ? "doc.text.magnifyingglass" : "checkmark.circle", description: Text(summary?.needsAnalysis == true ? "Return to Manage audiobook and analyze this chapter to find its speakers." : "The selected chapter has no pending speaker reviews.")).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.destination = nil } } } }
            }
        case .pronunciation: PronunciationEditorView(language: reader.book?.language ?? "en")
        case .generation:
            AudiobookSetupView(request: setupRequest, reader: reader, state: state, initialDestination: .generation)
        case .recordings:
            AudiobookSetupView(request: setupRequest, reader: reader, state: state, initialDestination: .saved, selectedChapter: chapter)
        }
    }
    private var setupRequest: AudiobookSetupRequest {
        .init(bookID: request.bookID, chapterTitle: chapter?.title ?? request.chapterTitle, scope: request.scope, mode: mode, snapshot: request.snapshot)
    }
    private func load() async {
        guard !loading, let local = reader.book else { return }
        loading = true; defer { loading = false }
        error = nil
        book = companion.books.first { $0.sourceSha256 == local.sourceSHA256 }
        do {
            if companion.paired { try await companion.refreshNarrationInventory(); book = try await companion.upload(local, library: library) }
            if chapterID.isEmpty, let book {
                // The new immutable reader capture is authoritative. A retained
                // audio selection may belong to a previously played chapter.
                chapterID = book.chapters.first { request.snapshot.hrefs.indices.contains(request.snapshot.current.resource) && ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(request.snapshot.hrefs[request.snapshot.current.resource]) }?.id
                    ?? book.chapters.first?.id ?? ""
            }
            await refreshMetadata()
            guard !Task.isCancelled else { return }
            // Loading describes only initial inventory. Long-lived server
            // polling must leave Keep reading available on a reopened screen.
            loading = false
            beginRecovery()
        } catch { if !Task.isCancelled { self.error = CompanionClient.narrationMessage(for: error) } }
    }
    private func refreshMetadata() async {
        guard let book, companion.paired else { return }
        do {
            let service = companion.castService(bookID: book.id)
            if draft?.busy != true { await draft?.load(book: book, service: service) }
            statuses = try await companion.chapterAnalysisStatus(book.id)
            review = try await companion.castReview(book)
            error = nil
        } catch { if !Task.isCancelled { self.error = CompanionClient.narrationMessage(for: error) } }
    }
    private func beginRecovery() {
        guard !loading, !state.working, draft?.working != true,
              draft?.awaitingAnalysisConfirmation != true, !Task.isCancelled else { return }
        action?.cancel()
        action = Task { await recoverSelectedAnalysis() }
    }
    private func recoverSelectedAnalysis() async {
        guard !Task.isCancelled, let book, let draft, companion.paired, !draft.working else { return }
        let service = companion.castService(bookID: book.id)
        if draft.canResumeAnalysis { await draft.load(book: book, service: service) }
        else if !draft.busy, let id = statuses.first(where: { $0.chapterId == chapterID })?.analysisId {
            do {
                let job = try await companion.analysis(id)
                guard !Task.isCancelled else { return }
                await draft.resumeExisting(book: book, job: job, service: service)
            } catch { if !Task.isCancelled { self.error = CompanionClient.narrationMessage(for: error) } }
        }
        guard !Task.isCancelled else { return }
        await refreshMetadata()
    }
    private func startAnalysis() {
        guard let book, let draft, !chapterID.isEmpty, !draft.busy else { return }
        let selectedID = chapterID
        action = Task {
            await draft.analyze(book: book, hosted: true, service: companion.castService(bookID: book.id), chapterIDs: [selectedID], force: statuses.contains { $0.chapterId == selectedID && $0.status != "not_analyzed" })
            guard !Task.isCancelled else { return }
            await refreshMetadata()
        }
    }
    private func saveDraft() async {
        guard let book, let draft else { return }
        if await draft.save(service: companion.castService(bookID: book.id)) { await refreshMetadata() }
    }
    private func prepareRecordings() {
        guard !state.working else { return }
        state.mode = mode; destination = .recordings
    }
    private func generate(_ scope: NarrationScope) {
        guard let chapter, let originalBook = book, let local = reader.book, !state.working else { return }
        let selectedID = chapter.id, selectedMode = mode
        action = Task {
            state.working = true; defer { state.working = false }
            error = nil
            do {
                try await companion.requireSourceRanges(); try await companion.requireSourceRangeCast()
                try await companion.refreshNarrationInventory()
                let remote = try await companion.upload(local, library: library)
                guard remote.id == originalBook.id, request.bookID == local.id,
                      remote.sourceSha256.lowercased() == local.sourceSHA256.lowercased() else { throw BookError.message("Open this book again to set up its audio.") }
                let selection: ReaderSourceSelection
                if scope == .page {
                    guard pageAvailable else { throw BookError.message("Open this chapter in the reader to select a page.") }
                    var snapshot = request.snapshot; snapshot.scope = .page
                    selection = try ReaderSourceMapper.resolve(snapshot, book: remote)
                    guard let exact = remote.chapters.first(where: { $0.id == selectedID }),
                          selection.ranges.allSatisfy({ range in exact.segments.contains { $0.id == range.segmentId } }) else { throw BookError.message("The captured page belongs to a different chapter.") }
                } else {
                    selection = try ManageAudiobookSource.chapter(book: remote, chapterID: selectedID, localSHA256: local.sourceSHA256)
                }
                let voice: RemoteVoice, plan: [NarrationSpan]?
                if selectedMode == .cast {
                    let draft = companion.castDraft(for: remote.id)
                    guard !draft.dirty, !draft.busy else { throw BookError.message("Save your cast changes and finish analysis before generating full cast audio.") }
                    let inventory = try await companion.castReview(remote)
                    let coverage = try await companion.chapterAnalysisStatus(remote.id)
                    guard CastReview.chaptersNeedingAnalysis([selectedID], statuses: coverage, inventory: inventory).isEmpty else { throw BookError.message("Analyze this chapter before generating full cast audio.") }
                    try CastReview.requireReady(inventory, book: remote, ranges: selection.ranges)
                    let saved = try await companion.fetchCast(remote.id)
                    let prepared = try ReaderCastPlan.build(cast: saved, book: remote, ranges: selection.ranges, voices: companion.voices, engines: companion.engines)
                    voice = prepared.narrator; plan = prepared.spans
                } else { voice = try ReaderNarrator.kyon(voices: companion.voices, engines: companion.engines); plan = nil }
                let job = try await companion.generate(book: remote, segments: selection.ranges.map(\.segmentId), voice: voice,
                    rules: companion.narrationPronunciations, announce: false, narrationPlan: plan,
                    sourceRanges: selection.ranges, narrationMode: selectedMode.wireMode)
                // Accepted generation does not start playback or change the
                // reader location. Shared state gives the player its exact take.
                generatedID = job.id; state.invalidatePlaybackIntent(); state.mode = selectedMode
                state.remote = remote; state.selection = selection; state.voice = voice; state.plan = plan ?? []
                state.playbackScope = scope; state.snapshot = scope == .page ? request.snapshot : nil
                state.selectedJobID = job.id; state.candidates = [job]; state.readyIDs = []; state.savedJobID = nil
                state.pollRevision += 1; state.showingSelection = false; state.error = nil
            } catch { self.error = CompanionClient.narrationMessage(for: error) }
        }
    }
}
