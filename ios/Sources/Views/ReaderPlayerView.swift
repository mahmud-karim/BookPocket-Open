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
    @State private var chooser: Chooser?
    @State private var discovering = false
    @State private var pendingDiscovery = false
    private enum Chooser { case narrator, scope }
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
        case production, scope, chapters([DownloadedChapterGroup])
        var id: String {
            switch self { case .production: return "production"; case .scope: return "scope"; case .chapters: return "chapters" }
        }
    }
    private var canPlay: Bool { !discovering && (state.mode == .device || active || (job.map { state.readyIDs.contains($0.id) } ?? false)) }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if let chooser {
                        choices(chooser, wide: geometry.size.width > geometry.size.height * 1.5)
                    } else if geometry.size.width > geometry.size.height * 1.5 {
                        HStack(alignment: .center, spacing: 20) {
                            VStack(spacing: 10) { narrator; chapterRow; HStack { speedControl; Spacer(); sleepControl } }.frame(maxWidth: .infinity)
                            VStack(spacing: 10) { transport(wide: true); actions }.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 10) { narrator; chapterRow; transport(); actions }
                    }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Obsidian.background)
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader.player.surface")
                .navigationTitle("Read aloud").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if chooser != nil { Button("Back") { chooser = nil }.accessibilityIdentifier("reader.player.choice.back") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { state.invalidatePlaybackIntent(); if let onClose { onClose() } else { dismiss() } } }
                }
                .sheet(item: $detail) { item in
                    NavigationStack {
                        Group {
                            if case .chapters(let groups) = item { chapters(groups) }
                            else if case .scope = item {
                                GeometryReader { geometry in
                                    choices(.scope, wide: geometry.size.width > geometry.size.height * 1.5)
                                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 20) {
                                        generatedControls
                                        if let error = state.error { Text(error).foregroundStyle(.red) }
                                        if state.mode == .cast { Button("Set up cast", systemImage: "person.2") { Task { await openCast() } }.frame(minHeight: 48).disabled(state.working).accessibilityIdentifier("reader.player.cast") }
                                        if state.snapshot != nil {
                                            Text(state.selection?.title ?? state.snapshot?.scope.title ?? "Selected words").font(.headline)
                                            Text(state.preview).font(.system(.body, design: .serif)).textSelection(.enabled).accessibilityIdentifier("reader.generation.preview")
                                            Text("Captured from the open book. Turn the page, then choose Generate again to select different words.").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(20)
                                }
                            }
                        }.background(Obsidian.background).navigationTitle(item.id == "chapters" ? "Chapters" : "Narration").navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    if case .scope = item { Button("Back") { detail = .production } }
                                }
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } }
                            }
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
                .onChange(of: reader.location) { if !(active && player.isPlaying) && !state.working && !reader.capturingScope && !state.showingSelection && state.mode != .device { refreshLocal() } }
        }.tint(Obsidian.accent)
            .onDisappear { state.invalidatePlaybackIntent() }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.disabled)
    }
    @ViewBuilder private var narrator: some View {
        if dynamicTypeSize.isAccessibilitySize {
                Button { chooser = .narrator } label: { HStack { Text(state.mode.title).font(.headline); Image(systemName: "chevron.down").font(.system(size: 14)) }.frame(minHeight: 48).contentShape(.rect) }
                    .disabled(state.working || reader.capturingScope || discovering).accessibilityIdentifier("reader.player.narrator")
        } else {
            HStack(spacing: 0) {
                ForEach(ReaderVoiceMode.allCases) { mode in
                    Button { if state.mode != mode { select(mode) } } label: {
                        Text(mode.title).font(.subheadline.weight(.medium)).lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(state.mode == mode ? Obsidian.accent : .clear, in: .rect(cornerRadius: 10))
                            .foregroundStyle(state.mode == mode ? Obsidian.onAccent : .primary).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityIdentifier("reader.voice." + mode.rawValue)
                        .accessibilityAddTraits(state.mode == mode ? .isSelected : [])
                        .disabled(state.working || reader.capturingScope || discovering)
                }
            }.padding(3).background(Obsidian.surface, in: .rect(cornerRadius: 13))
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader.player.narrator")
        }
    }
    private var currentChapter: String {
        guard let location = reader.location else { return "Choose a chapter" }
        let matches = flatten(reader.chapters).filter { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(location.href.string) }
        if matches.count == 1, let title = matches.first?.title { return title }
        return location.title ?? "Choose a chapter"
    }
    private var chapterRow: some View {
        HStack(spacing: 8) {
            Button { openChapters() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "book").font(.system(size: 22))
                    Text(currentChapter).font(.subheadline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 14))
                }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 48).contentShape(.rect)
            }.buttonStyle(.plain).background(Obsidian.surface, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Chapters").accessibilityValue(currentChapter).accessibilityIdentifier("reader.player.chapters")
            if state.mode != .device {
                control("Narration details and takes", icon: state.error == nil ? "ellipsis.circle" : "exclamationmark.circle", id: "details") { detail = .production }
            }
        }
    }
    private var speedControl: some View {
        Menu {
            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { player.rate = rate } }
        } label: { Text("\(player.rate.formatted())×").font(.system(size: 16, weight: .medium)).monospacedDigit().frame(minWidth: 48, minHeight: 48).contentShape(.rect) }
            .accessibilityLabel("Playback speed").accessibilityIdentifier("reader.player.speed")
    }
    private var sleepControl: some View {
        Menu {
            Button("Off") { player.sleep(minutes: nil) }
            ForEach([5, 15, 30, 60], id: \.self) { minutes in Button("\(minutes) minutes") { player.sleep(minutes: minutes) } }
        } label: { Image(systemName: "moon").font(.system(size: 22)).frame(minWidth: 48, minHeight: 48).contentShape(.rect) }
            .accessibilityLabel("Sleep timer").accessibilityIdentifier("reader.player.sleep")
    }
    private func transport(wide: Bool = false) -> some View {
        VStack(spacing: 8) {
            Text(readiness).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                .accessibilityIdentifier("reader.player.readiness")
            if active && player.duration > 0 {
                Slider(value: Binding(get: { player.elapsed }, set: { state.invalidatePlaybackIntent(); player.seek($0) }), in: 0...max(1, player.duration)) { Text("Audio position") }
                    .accessibilityIdentifier("reader.player.seek")
            }
            HStack(spacing: 0) {
                if !wide { speedControl; Spacer(minLength: 0) }
                control(state.mode == .device ? "Previous passage" : "Back 15 seconds", icon: state.mode == .device ? "backward.end" : "gobackward.15", id: "backward") { state.invalidatePlaybackIntent(); player.skip(-15) }.disabled(!active)
                Spacer(minLength: 0)
                control(active && player.isPlaying ? "Pause" : "Play", icon: active && player.isPlaying ? "pause.fill" : "play.fill", id: "toggle") { play() }
                    .background(canPlay ? Obsidian.accent : .gray.opacity(0.25), in: .circle)
                    .foregroundStyle(canPlay ? Obsidian.onAccent : .secondary)
                    .disabled(!canPlay).accessibilityValue(active && player.isPlaying ? "Playing" : "Paused")
                Spacer(minLength: 0)
                control(state.mode == .device ? "Next passage" : "Forward 15 seconds", icon: state.mode == .device ? "forward.end" : "goforward.15", id: "forward") { state.invalidatePlaybackIntent(); player.skip(15) }.disabled(!active)
                if !wide { Spacer(minLength: 0); sleepControl }
            }
        }.frame(maxWidth: .infinity)
    }
    private var readiness: String {
        if state.working { return "Preparing narration…" }
        if discovering { return "Checking this page…" }
        if let job, ["queued", "running", "paused"].contains(job.status) { return "\(job.status.capitalized) · \(job.completedSegments)/\(job.totalSegments) passages" }
        if state.showingSelection && !companion.paired { return "Pair your PC to generate · open details" }
        if state.error != nil { return "Needs attention · open details" }
        return active ? (player.isPlaying ? "Playing" : "Paused") : state.mode == .device ? "Ready on this iPhone" : canPlay ? "Ready offline" : "No matching audio"
    }
    private var actions: some View {
        VStack(spacing: 8) {
            if let job, job.status == "completed", !state.readyIDs.contains(job.id) {
                Button("Download & play") { Task { await downloadAndPlay(job) } }.frame(minHeight: 48).accessibilityIdentifier("reader.player.download")
                    .disabled(state.working)
            } else if state.mode != .device { generateMenu }
        }.frame(maxWidth: .infinity)
    }
    private var generateMenu: some View {
        Button { chooser = .scope } label: {
            Text("Generate").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48).contentShape(.rect)
        }.buttonStyle(.plain).foregroundStyle(Obsidian.onAccent).background(Obsidian.accent, in: .rect(cornerRadius: 12))
            .disabled(state.working || reader.capturingScope || discovering || !reader.pageReady).accessibilityIdentifier("reader.player.generate")
    }
    private func choices(_ choice: Chooser, wide: Bool) -> some View {
        // Keep the choices in this panel's real coordinate space. A nested
        // system menu can report displaced accessibility frames in the reader.
        let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
        return VStack(spacing: 12) {
            if choice == .scope && !dynamicTypeSize.isAccessibilitySize && !wide {
                Text("What would you like to generate?").font(.headline).multilineTextAlignment(.center)
            }
            layout {
            if choice == .narrator {
                ForEach(ReaderVoiceMode.allCases) { mode in
                    choiceButton(mode.title, icon: state.mode == mode ? "checkmark" : "waveform", id: "reader.voice." + mode.rawValue) {
                        chooser = nil
                        if state.mode != mode { select(mode) }
                    }.accessibilityAddTraits(state.mode == mode ? .isSelected : [])
                }
            } else {
                ForEach(NarrationScope.allCases) { scope in
                    Button { chooser = nil; capture(scope) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: scope == .page ? "doc.text" : "book").font(.system(size: 24))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scope.title).font(.headline)
                                if !dynamicTypeSize.isAccessibilitySize { Text(scope == .page ? "The words on screen" : "The complete chapter").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 14))
                        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(12)
                            .background(Obsidian.surface, in: .rect(cornerRadius: 14)).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityIdentifier("reader.generate." + scope.rawValue)
                        .accessibilityHint(scope == .page ? "Generate exactly the words on the current page" : "Generate the complete current chapter")
                }
            }
            }
            if choice == .scope {
                Button("Cancel") { if detail != nil { detail = .production } else { chooser = nil } }
                    .frame(minWidth: 48, minHeight: 48).accessibilityIdentifier("reader.generate.cancel")
            }
        }
    }
    private func choiceButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(8)
                .background(Obsidian.surface, in: .rect(cornerRadius: 12)).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private func chapters(_ chapterGroups: [DownloadedChapterGroup]) -> some View {
        List {
            Section("Book chapters") {
                ForEach(Array(flatten(reader.chapters).enumerated()), id: \.offset) { index, link in
                    Button(link.title ?? "Chapter \(index + 1)") { Task {
                        state.invalidatePlaybackIntent()
                        if player.bookID == reader.bookID {
                            player.onLocator = nil
                            if player.subtitle == "On-device voice" { player.stop() } else { player.pause() }
                        }
                        if await reader.navigator?.go(to: link) == true {
                            detail = nil
                            if player.bookID == reader.bookID { reader.connectPlayback(player) }
                            if state.mode != .device { refreshLocal() }
                        } else { state.error = "This chapter could not be opened. Try again from Contents." }
                    } }.accessibilityIdentifier("reader.player.chapter.\(index)")
                }
            }
            if state.mode != .device {
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
        Button { detail = .scope } label: { Label(canPlay ? "Generate another selection" : "Generate", systemImage: "waveform.badge.plus").frame(minHeight: 48) }
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
        guard !discovering else { pendingDiscovery = true; return }
        discovering = true
        state.readyIDs = []
        Task {
            defer {
                discovering = false
                if pendingDiscovery { pendingDiscovery = false; refreshLocal() }
            }
            do { let snapshot = try await reader.captureScope(.page); if let local = reader.book { state.discover(snapshot: snapshot, local: local, companion: companion) } }
            catch { state.error = error.localizedDescription; state.readyIDs = []; state.selectedJobID = nil }
        }
    }
    private func capture(_ scope: NarrationScope) {
        state.invalidatePlaybackIntent()
        Task {
            do {
                let snapshot = try await reader.captureScope(scope)
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
