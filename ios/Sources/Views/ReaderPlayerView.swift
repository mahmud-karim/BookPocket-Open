import SwiftUI
import ReadiumShared

struct ReaderPlayerView: View {
    let reader: ReaderModel
    @Bindable var state: ReaderPlayerState
    var onClose: (() -> Void)? = nil
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showPairing = false
    @State private var showCast = false
    private var job: RemoteJob? { companion.jobs.first { $0.id == state.selectedJobID } }
    private var active: Bool {
        guard player.bookID == reader.bookID else { return false }
        if state.mode == .device { return player.subtitle == "On-device voice" }
        guard let job else { return false }
        return companion.downloads.contains { $0.jobID == job.id && $0.localBookID == reader.bookID && $0.id == reader.book?.audioAssetID }
            && player.subtitle != "On-device voice"
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var detail: Detail?
    private enum Detail: Identifiable {
        case production, chapters([DownloadedChapterGroup])
        var id: String { if case .production = self { return "production" }; return "chapters" }
    }
    private var canPlay: Bool { state.mode == .device || active || (job.map { state.readyIDs.contains($0.id) } ?? false) }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if geometry.size.width > geometry.size.height * 1.5 {
                        HStack(alignment: .center, spacing: 24) { transport; actions.frame(maxWidth: 220) }
                    } else {
                        VStack(spacing: 12) { transport; actions }
                    }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Obsidian.background)
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader.player.surface")
                .navigationTitle("Read aloud").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { state.invalidatePlaybackIntent(); if let onClose { onClose() } else { dismiss() } } } }
                .sheet(item: $detail) { item in
                    NavigationStack {
                        Group {
                            if case .chapters(let groups) = item { chapters(groups) }
                            else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 20) {
                                        generatedControls
                                        if let error = state.error { Text(error).foregroundStyle(.red) }
                                        if state.mode == .cast { Button("Set up cast", systemImage: "person.2") { Task { await openCast() } }.frame(minHeight: 48).disabled(state.working).accessibilityIdentifier("reader.player.cast") }
                                        if state.showingSelection {
                                            Text(state.selection?.title ?? state.snapshot?.scope.title ?? "Selected words").font(.headline)
                                            Text(state.preview).font(.system(.body, design: .serif)).textSelection(.enabled).accessibilityIdentifier("reader.generation.preview")
                                            Text("Captured from the open book. Turn the page, then choose Generate again to select different words.").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(20)
                                }
                            }
                        }.background(Obsidian.background).navigationTitle(item.id == "chapters" ? "Chapters" : "Narration").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
                    }.tint(Obsidian.accent)
                        .sheet(isPresented: $showPairing, onDismiss: { refresh() }) { PairingView() }
                        .sheet(isPresented: $showCast, onDismiss: { refreshPreparation() }) { if let remote = state.remote { CastView(book: remote) } }
                }
                .task(id: (state.selectedJobID ?? "") + ":\(state.pollRevision)") {
                    guard let id = state.selectedJobID else { return }
                    while !Task.isCancelled {
                        guard let current = companion.jobs.first(where: { $0.id == id }), ["queued", "running"].contains(current.status) else { return }
                        do { _ = try await companion.refreshJob(id) } catch { state.error = CompanionClient.narrationMessage(for: error); return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    }
                }
                .onChange(of: reader.location) { if !active && !state.working && !reader.capturingScope && !state.showingSelection && state.mode != .device { refreshLocal() } }
        }.tint(Obsidian.accent)
            .onDisappear { state.invalidatePlaybackIntent() }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.disabled)
    }
    private var transport: some View {
        VStack(spacing: 12) {
            HStack {
                Menu {
                    ForEach(ReaderVoiceMode.allCases) { mode in
                        Button { select(mode) } label: { Label(mode.title, systemImage: state.mode == mode ? "checkmark" : "waveform") }
                            .accessibilityIdentifier("reader.voice." + mode.rawValue)
                    }
                } label: { HStack { Text(state.mode.title).font(.headline); Image(systemName: "chevron.down").font(.system(size: 14)) }.frame(minHeight: 48).contentShape(.rect) }
                    .disabled(state.working || reader.capturingScope).accessibilityIdentifier("reader.player.narrator")
                Spacer(minLength: 4)
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { player.rate = rate } }
                } label: { Text("\(player.rate.formatted())×").font(.system(size: 17, weight: .medium)).monospacedDigit().frame(minWidth: 48, minHeight: 48).contentShape(.rect) }
                    .accessibilityLabel("Playback speed").accessibilityIdentifier("reader.player.speed")
            }
            if active && player.duration > 0 {
                Slider(value: Binding(get: { player.elapsed }, set: { state.invalidatePlaybackIntent(); player.seek($0) }), in: 0...max(1, player.duration)) { Text("Audio position") }
                    .accessibilityIdentifier("reader.player.seek")
            }
            HStack {
                control(state.mode == .device ? "Previous passage" : "Back 15 seconds", icon: state.mode == .device ? "backward.end" : "gobackward.15", id: "backward") { state.invalidatePlaybackIntent(); player.skip(-15) }.disabled(!active)
                Spacer(minLength: 0)
                control(active && player.isPlaying ? "Pause" : "Play", icon: active && player.isPlaying ? "pause.fill" : "play.fill", id: "toggle") { play() }
                    .disabled(!canPlay).accessibilityValue(active && player.isPlaying ? "Playing" : "Paused")
                Spacer(minLength: 0)
                control(state.mode == .device ? "Next passage" : "Forward 15 seconds", icon: state.mode == .device ? "forward.end" : "goforward.15", id: "forward") { state.invalidatePlaybackIntent(); player.skip(15) }.disabled(!active)
            }
            Text(active ? (player.isPlaying ? "Playing" : "Paused") : state.mode == .device ? "Ready on this iPhone" : canPlay ? "Ready offline" : "No matching audio")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("reader.player.readiness")
        }.frame(maxWidth: .infinity)
    }
    private var actions: some View {
        VStack(spacing: 8) {
            HStack {
                if state.mode != .device { generateMenu }
                control("Chapters", icon: "list.bullet", id: "chapters") { openChapters() }
                Spacer(minLength: 0)
                Menu {
                    Button("Off") { player.sleep(minutes: nil) }
                    ForEach([5, 15, 30, 60], id: \.self) { minutes in Button("\(minutes) minutes") { player.sleep(minutes: minutes) } }
                } label: { Image(systemName: "moon").font(.system(size: 22)).frame(minWidth: 48, minHeight: 48).contentShape(.rect) }
                    .accessibilityLabel("Sleep timer").accessibilityIdentifier("reader.player.sleep")
                if state.mode != .device { control("Narration details and takes", icon: "ellipsis.circle", id: "details") { detail = .production } }
            }
            if state.working { ProgressView("Preparing…").font(.caption).accessibilityIdentifier("reader.player.working") }
            else if let job, ["queued", "running", "paused"].contains(job.status) {
                ProgressView(value: Double(job.completedSegments), total: Double(max(1, job.totalSegments))) { Text("\(job.status.capitalized) · \(job.completedSegments)/\(job.totalSegments)").font(.caption) }
            } else if let job, job.status == "completed", !state.readyIDs.contains(job.id) {
                Button("Download & play") { Task { await downloadAndPlay(job) } }.frame(minHeight: 48).accessibilityIdentifier("reader.player.download")
            } else if state.error != nil { Button("Needs attention — details") { detail = .production }.font(.caption).frame(minHeight: 48) }
        }.frame(maxWidth: .infinity)
    }
    private var generateMenu: some View {
        Menu {
            ForEach(NarrationScope.allCases) { scope in
                Button(scope.title, systemImage: scope == .page ? "doc.text" : "book") { capture(scope) }.accessibilityIdentifier("reader.generate." + scope.rawValue)
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize { Label("Generate", systemImage: "waveform.badge.plus").labelStyle(.iconOnly) }
                else { Label("Generate", systemImage: "waveform.badge.plus") }
            }.font(dynamicTypeSize.isAccessibilitySize ? .system(size: 22) : .body).frame(minWidth: 48, minHeight: 48).contentShape(.rect)
        }.disabled(state.working || reader.capturingScope || !reader.pageReady).accessibilityIdentifier("reader.player.generate")
    }
    private func chapters(_ chapterGroups: [DownloadedChapterGroup]) -> some View {
        List {
            if state.mode == .device {
                ForEach(Array(flatten(reader.chapters).enumerated()), id: \.offset) { index, link in
                    Button(link.title ?? "Chapter \(index + 1)") { Task {
                        if active { if await player.selectSpeechChapter(link) { reader.connectPlayback(player); detail = nil } }
                        else if await reader.navigator?.go(to: link) == true { detail = nil }
                    } }.accessibilityIdentifier("reader.player.chapter.\(index)")
                }
            } else {
                ForEach(chapterGroups) { group in
                    Section(group.title) {
                        ForEach(group.takes) { take in
                            Button("\(take.scope) · \(take.description)") { selectChapter(take) }.accessibilityIdentifier("reader.player.chapter." + take.id)
                        }
                    }
                }
                if chapterGroups.isEmpty { Text("No downloaded chapters for this narrator. Open a chapter in Contents and generate it.") }
            }
        }
    }
    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
    private func openChapters() {
        var chapterGroups: [DownloadedChapterGroup] = []
        if let local = reader.book {
            chapterGroups = companion.downloadedChapterGroups(for: local).compactMap { group in
                var result = group
                result.takes = group.takes.filter { take in companion.jobs.contains { $0.id == take.jobID && ReaderTakeMatch.mode($0) == state.mode } }
                return result.takes.isEmpty ? nil : result
            }
        }
        detail = .chapters(chapterGroups)
    }
    private func selectChapter(_ take: DownloadedChapterTake) {
        guard let job = companion.jobs.first(where: { $0.id == take.jobID }), ReaderTakeMatch.mode(job) == state.mode,
              let remote = companion.books.first(where: { $0.id == job.bookId }), remote.sourceSha256 == reader.book?.sourceSHA256 else { return }
        state.invalidatePlaybackIntent()
        companion.play(take.firstRecord, library: library, player: player, fromBeginning: true)
        guard player.isPlaying else { state.error = player.error; return }
        state.remote = remote; state.selectedJobID = job.id; state.readyIDs.insert(job.id)
        reader.connectPlayback(player); detail = nil
    }
    @ViewBuilder private var generatedControls: some View {
        if state.working { ProgressView("Preparing narration…").accessibilityIdentifier("reader.player.working") }
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
                    Button("Download & play", systemImage: "arrow.down.circle") { Task { await downloadAndPlay(job) } }
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
                        if active { player.pause() }; state.selectedJobID = take.id; state.showingSelection = false; state.pollRevision += 1
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
        Menu {
            ForEach(NarrationScope.allCases) { scope in
                Button(scope.title, systemImage: scope == .page ? "doc.text" : "book") { capture(scope) }.accessibilityIdentifier("reader.generate." + scope.rawValue)
            }
        } label: { Label(canPlay ? "Generate another selection" : "Generate", systemImage: "waveform.badge.plus").frame(minHeight: 48) }
            .buttonStyle(.bordered).disabled(state.working || reader.capturingScope || !reader.pageReady).accessibilityIdentifier("reader.player.generate")
        if !companion.paired { Button("Pair your PC", systemImage: "qrcode.viewfinder") { showPairing = true }.frame(minHeight: 48) }
        else { Button("Refresh connection & takes", systemImage: "arrow.clockwise") { refresh() }.font(.caption).frame(minHeight: 48).disabled(state.working) }
    }
    private func control(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 22)).frame(minWidth: 48, minHeight: 48).contentShape(.rect) }.accessibilityIdentifier("reader.player." + id)
    }
    private func select(_ mode: ReaderVoiceMode) {
        state.invalidatePlaybackIntent()
        if active && state.mode != mode { player.pause() }
        state.mode = mode; state.error = nil; state.needsCast = false; state.showingSelection = false; state.voice = nil; state.selectedJobID = nil
        if mode != .device { refreshLocal() }
    }

    private func refreshLocal() {
        state.readyIDs = []
        Task {
            do { let snapshot = try await reader.captureScope(.page); if let local = reader.book { state.discover(snapshot: snapshot, local: local, companion: companion) } }
            catch { state.error = error.localizedDescription; state.readyIDs = [] }
        }
    }
    private func capture(_ scope: NarrationScope) {
        state.invalidatePlaybackIntent()
        Task {
            do { let snapshot = try await reader.captureScope(scope); detail = .production; await state.prepare(snapshot: snapshot, reader: reader, library: library, companion: companion) }
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
    private func play() {
        state.invalidatePlaybackIntent()
        if active { player.toggle(); reader.connectPlayback(player); return }
        if state.mode == .device {
            guard let publication = reader.publication, let book = reader.book else { return }
            player.speak(publication: publication, book: book, from: reader.navigator?.currentLocation); reader.connectPlayback(player); return
        }
        guard let job, state.readyIDs.contains(job.id), let selection = state.selection else { return }
        playDownloaded(job, selection: selection)
    }
    private func playDownloaded(_ job: RemoteJob, selection: ReaderSourceSelection) {
        guard let first = selection.ranges.first,
              let record = companion.orderedDownloads(jobID: job.id).first(where: { $0.asset.segmentId == first.segmentId }) else { return }
        companion.play(record, library: library, player: player, fromBeginning: true)
        guard player.isPlaying else { state.error = player.error; state.readyIDs.remove(job.id); return }
        // Aligned assets can start near the first captured word. Never guess a
        // proportional timestamp; unaligned takes start at their passage boundary.
        if let timing = record.asset.timings.first(where: { $0.startOffset <= first.startOffset && $0.endOffset > first.startOffset }) { player.seek(timing.start) }
        reader.connectPlayback(player)
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
        }, play: { playDownloaded(job, selection: selection) })
    }
    private func openCast() async {
        guard !state.working else { return }
        if state.remote == nil, let book = reader.book {
            do { state.remote = try await companion.upload(book, library: library) } catch { state.error = CompanionClient.narrationMessage(for: error); return }
        }
        showCast = state.remote != nil
    }
}
