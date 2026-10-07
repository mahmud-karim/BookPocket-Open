import SwiftUI
import ReadiumShared

/// Playback-only panel; setup is handed to the reader through one explicit route.
struct ReaderPlayerView: View {
    let reader: ReaderModel
    @Bindable var state: ReaderPlayerState
    var onClose: (() -> Void)? = nil
    /// A short portrait phone trades the title row for visible book text.
    var compact = false
    let onManage: () -> Void
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var discovering = false
    @State private var pendingDiscovery = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var sheet: Choice?
    private enum Choice: Identifiable {
        case source, recordings, speed, sleep, chapters([DownloadedChapterGroup])
        var id: String { switch self { case .source: "source"; case .recordings: "recordings"; case .speed: "speed"; case .sleep: "sleep"; case .chapters: "chapters" } }
    }
    private var job: RemoteJob? { companion.jobs.first { $0.id == state.selectedJobID } }
    private var recording: DownloadedRecordingSelection? {
        guard let job, let selection = state.selection, state.readyIDs.contains(job.id) else { return nil }
        return try? DownloadedRecordingSelection.reader(job: job, selection: selection, records: companion.orderedDownloads(jobID: job.id))
    }
    private var preparedDuration: Double? { recording.flatMap { companion.recordingDuration($0) } }
    private var recordingIssue: String? {
        guard state.mode != .device, let job, job.status == "completed", let selection = state.selection else { return nil }
        if let book = state.remote {
            do { try RangedAudioValidation.validate(job: job, book: book) }
            catch { return error.localizedDescription }
        }
        let records = companion.orderedDownloads(jobID: job.id)
        guard companion.downloads.contains(where: { $0.jobID == job.id }) || state.readyIDs.contains(job.id) else { return nil }
        do {
            let selected = try DownloadedRecordingSelection.reader(job: job, selection: selection, records: records)
            if companion.recordingDuration(selected) == nil { return "This recording is damaged or its timing is invalid. Open Manage audiobook to download it again." }
        } catch { return error.localizedDescription }
        return nil
    }
    private var active: Bool {
        guard player.bookID == reader.bookID else { return false }
        if state.mode == .device { return player.subtitle == "On-device voice" }
        guard let recording else { return false }
        return player.recordingID == recording.id && player.subtitle != "On-device voice"
    }
    private var currentChapter: String {
        guard let location = reader.location else { return "Choose a chapter" }
        let matches = flatten(reader.chapters).filter { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(location.href.string) }
        if matches.count == 1, let title = matches.first?.title { return title }
        return location.title ?? "Choose a chapter"
    }

    private var recordings: [ReaderAudioRecording] {
        guard let local = reader.book,
              let book = companion.books.first(where: { $0.sourceSha256 == local.sourceSHA256 }),
              let href = reader.location?.href.string,
              let chapter = book.chapters.first(where: { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(href) }) else { return [] }
        return ReaderAudioCatalog.recordings(book: book, chapter: chapter, mode: state.mode,
            jobs: companion.jobs, localBookID: local.id, downloads: companion.orderedDownloads)
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
        sheet = nil
    }
    private var canPlay: Bool { !discovering && (state.mode == .device || (recordingIssue == nil && (active || preparedDuration != nil))) }
    private var scopeName: String { state.playbackScope == .page ? "page" : "chapter" }
    private var recordingTitle: String {
        let scope = state.playbackScope == .page ? "page" : "chapter"
        guard let job else { return "\(scope.capitalized) audio" }
        let alternates = recordings.filter { $0.scope == state.playbackScope }
        let take = alternates.count > 1 ? " · Take \((alternates.firstIndex { $0.id == job.id } ?? 0) + 1)" : ""
        return "\(canPlay ? "Saved " : "")\(scope) audio\(take)"
    }
    private var readiness: String {
        if discovering { return "Checking this \(scopeName)…" }
        if let error = state.attention ?? recordingIssue { return error }
        if state.mode == .device { return "Ready on this iPhone" }
        if state.requiresTakeSelection { return "Choose a matching recording" }
        if let job, state.readyIDs.contains(job.id), recording == nil { return "This recording cannot play these exact words. Open Manage audiobook." }
        if canPlay { return active ? (player.isPlaying ? "Playing" : "Paused") : "Ready offline" }
        if let job, job.status == "completed" { return "Audio on PC · download in Manage audiobook" }
        if let job, ["queued", "running", "paused", "failed", "cancelled"].contains(job.status) {
            return "\(job.status.capitalized) · \(job.error ?? "Open Manage audiobook for this recording")"
        }
        return "No audio for this \(scopeName)"
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.5
            Group {
                if dynamicTypeSize.isAccessibilitySize { ScrollView { content(wide: false) } }
                else { content(wide: wide) }
            }.padding(.horizontal, 20).padding(.top, 12)
                .padding(.bottom, max(12, geometry.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.ignoresSafeArea(.container, edges: .bottom)
            .background(Obsidian.background.ignoresSafeArea(edges: .bottom))
            .foregroundStyle(.primary).environment(\.colorScheme, .dark).tint(Obsidian.accent)
            .accessibilityElement(children: .contain).accessibilityIdentifier("reader.player.surface")
            .accessibilityValue(player.speechLocator?.text.highlight ?? "")
            .sheet(item: $sheet) { choice in
                NavigationStack {
                    choiceView(choice).navigationTitle(choice.id == "source" ? "Playback source" : choice.id.capitalized)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
                }.preferredColorScheme(.dark).tint(Obsidian.accent)
            }
            .onChange(of: reader.location) {
                if !(active && player.isPlaying) && !state.working && state.mode != .device {
                    if scrubbing { pendingDiscovery = true } else { refreshLocal() }
                }
            }
            .onChange(of: companion.downloads.count) { if state.mode != .device { refreshLocal() } }
            .onDisappear { state.invalidatePlaybackIntent() }
    }
    private func content(wide: Bool) -> some View {
        let short = compact && !wide && !dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: short ? 6 : 8) {
            if short { HStack(spacing: 8) { chapterRow; closeButton } }
            else { HStack { Text("Read aloud").font(.title3.weight(.semibold)); Spacer(); closeButton } }
            if wide {
                HStack(spacing: 24) {
                    VStack(spacing: 4) { chapterRow; scopePicker; recordingLabel; if !canPlay { status }; setupLink() }.frame(maxWidth: .infinity)
                    VStack(spacing: 8) { timeline; transport(); settings }.frame(maxWidth: .infinity)
                }
            } else if short {
                scopePicker; recordingLabel
                if showsStatus { status.lineLimit(2).minimumScaleFactor(0.85) }
                timeline
                HStack(spacing: 0) { speedButton; Spacer(minLength: 0); transport(compact: true); Spacer(minLength: 0); sleepButton }.foregroundStyle(.secondary)
                setupLink(caption: false)
            } else {
                chapterRow; scopePicker; recordingLabel
                if showsStatus { status }
                timeline; transport(); settings; setupLink()
            }
        }
    }
    private var showsStatus: Bool { !canPlay || state.mode == .device || state.attention != nil || recordingIssue != nil }
    private var closeButton: some View {
        Button { state.invalidatePlaybackIntent(); if let onClose { onClose() } else { dismiss() } } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44).background(Obsidian.surface, in: .circle)
        }.buttonStyle(.plain).accessibilityLabel("Close Read aloud").accessibilityIdentifier("reader.player.close")
    }
    private var chapterRow: some View {
        Button { openChapters() } label: {
            HStack(spacing: 12) {
                Image(systemName: "book").font(.title3)
                Text(currentChapter).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
            }.padding(.horizontal, 14).frame(minHeight: 48).background(Obsidian.surface, in: .rect(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("Chapters").accessibilityValue(currentChapter).accessibilityIdentifier("reader.player.chapters")
    }
    @ViewBuilder private var scopePicker: some View {
        if state.mode != .device {
            HStack(spacing: 0) {
                ForEach(NarrationScope.allCases) { scope in
                    Button { selectScope(scope) } label: {
                        Text(scope == .page ? "Page" : "Chapter").font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(state.playbackScope == scope ? Obsidian.accent : Obsidian.surface, in: .rect(cornerRadius: 12)).contentShape(.rect)
                            .foregroundStyle(state.playbackScope == scope ? Obsidian.onAccent : .primary)
                    }.buttonStyle(.plain).accessibilityIdentifier("reader.scope." + scope.rawValue)
                        .accessibilityAddTraits(state.playbackScope == scope ? .isSelected : [])
                        .disabled(state.working || discovering || reader.capturingScope)
                }
            }.background(Obsidian.surface, in: .rect(cornerRadius: 12))
        }
    }
    private var recordingLabel: some View {
        HStack(spacing: 8) {
            Button { sheet = .source } label: {
                HStack(spacing: 4) { Text(state.mode.title); Image(systemName: "chevron.down").font(.caption) }.frame(minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityLabel("Playback source").accessibilityValue(state.mode.title).accessibilityIdentifier("reader.player.narrator")
                .disabled(state.working || discovering || reader.capturingScope)
            if state.mode != .device {
                Text("·")
                Button { sheet = .recordings } label: { Text(recordingTitle).lineLimit(2).frame(minHeight: 44).contentShape(.rect) }
                    .buttonStyle(.plain).accessibilityIdentifier("reader.player.saved")
                    .accessibilityLabel("Choose saved recording").accessibilityValue(job?.createdAt ?? "No recording selected")
            }
        }.font(.subheadline).foregroundStyle(.secondary)
    }
    private var status: some View {
        Text(readiness).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(state.attention == nil ? SwiftUI.Color.primary : SwiftUI.Color.red)
            .accessibilityIdentifier("reader.player.readiness")
    }
    private var timeline: some View {
        let total = active ? player.duration : preparedDuration ?? 0
        return VStack(spacing: 0) {
            // Keep the drag independent of AVPlayer construction and reader
            // follow/discovery. Publish one exact seek when the finger lifts.
            Slider(value: Binding(get: { scrubbing ? scrubPosition : (active ? player.elapsed : 0) }, set: {
                if scrubbing { scrubPosition = $0 } else { seek($0) }
            }), in: 0...max(1, total), onEditingChanged: { editing in
                if editing {
                    scrubPosition = active ? player.elapsed : 0
                    scrubbing = true
                } else {
                    let position = scrubPosition
                    scrubbing = false
                    seek(position)
                    if pendingDiscovery { pendingDiscovery = false; refreshLocal() }
                }
            }) { Text("Audio position") }
                .disabled(!canPlay || state.mode == .device).accessibilityIdentifier("reader.player.seek")
            if state.mode != .device && total > 0 {
                HStack {
                    Text(clock(scrubbing ? scrubPosition : (active ? player.elapsed : 0))).accessibilityIdentifier("reader.player.elapsed")
                    Spacer()
                    Text(clock(total)).accessibilityIdentifier("reader.player.duration")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
    private func transport(compact: Bool = false) -> some View {
        HStack(spacing: compact ? 24 : 36) {
            control(state.mode == .device ? "Previous passage" : "Back 15 seconds", icon: state.mode == .device ? "backward.end" : "gobackward.15", id: "backward") { skip(-15) }.disabled(!canPlay)
            Button { play() } label: {
                Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                    .frame(width: 68, height: 68).background(canPlay ? Obsidian.accent : .gray.opacity(0.25), in: .circle)
                    .foregroundStyle(canPlay ? Obsidian.onAccent : .secondary)
            }.buttonStyle(.plain).disabled(!canPlay).accessibilityLabel(active && player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("reader.player.toggle").accessibilityValue(active && player.isPlaying ? "Playing" : "Paused")
            control(state.mode == .device ? "Next passage" : "Forward 15 seconds", icon: state.mode == .device ? "forward.end" : "goforward.15", id: "forward") { skip(15) }.disabled(!canPlay)
        }.foregroundStyle(Obsidian.accent).padding(.vertical, compact ? 0 : 4)
    }
    private var speedButton: some View {
        Button { sheet = .speed } label: { Text("\(player.rate.formatted())×").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("Playback speed").accessibilityValue("\(player.rate.formatted())×").accessibilityIdentifier("reader.player.speed")
    }
    private var sleepButton: some View {
        control("Sleep timer", icon: "moon", id: "sleep") { sheet = .sleep }.accessibilityValue(player.sleepUntil == nil ? "Off" : "On")
    }
    private var settings: some View {
        HStack { speedButton; Spacer(); sleepButton }.foregroundStyle(.secondary)
    }
    private func setupLink(caption: Bool = true) -> some View {
        VStack(spacing: 4) {
            if state.mode != .device && !canPlay && !state.requiresTakeSelection {
                if caption { Text("Set up and generate it in Manage audiobook.").font(.caption).foregroundStyle(.secondary) }
                Button(action: onManage) {
                    HStack { Spacer(); Text("Set up \(scopeName) audio"); Image(systemName: "chevron.right"); Spacer() }
                        .frame(minHeight: 48).background(Obsidian.accent, in: .rect(cornerRadius: 12)).foregroundStyle(Obsidian.onAccent)
                }.buttonStyle(.plain).accessibilityLabel("Set up \(scopeName) audio").accessibilityIdentifier("reader.player.setup")
                    .disabled(discovering || reader.capturingScope)
            } else {
                Divider()
                Button(action: onManage) { HStack { Text("Manage audiobook"); Image(systemName: "chevron.right"); Spacer() }.frame(minHeight: 44).background(Obsidian.background).contentShape(.rect) }
                    .buttonStyle(.plain).accessibilityIdentifier("reader.player.manage")
            }
        }
    }
    @ViewBuilder private func choiceView(_ choice: Choice) -> some View {
        switch choice {
        case .chapters(let groups): chapters(groups)
        case .source:
            List { ForEach(ReaderVoiceMode.allCases) { mode in
                Button { select(mode); sheet = nil } label: { HStack { Text(mode.title); Spacer(); if state.mode == mode { Image(systemName: "checkmark") } }.frame(minHeight: 44) }
                    .accessibilityIdentifier("reader.voice." + mode.rawValue)
            } }
        case .recordings:
            List {
                ForEach(recordings) { recording in
                    Button { selectRecording(recording) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recording.scope == .page ? "Saved page audio" : "Full chapter").font(.headline)
                            Text(recording.preview).lineLimit(2)
                            Text(recording.job.createdAt ?? "Imported recording").font(.caption).foregroundStyle(.secondary)
                            Text("\(recording.offline ? "Ready offline" : "On PC") · \(clock(recording.duration))").font(.caption)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("reader.saved." + recording.id)
                }
                if state.candidates.isEmpty && recordings.isEmpty { Text("No matching recordings for this \(scopeName).") }
                ForEach(state.candidates.filter { candidate in !recordings.contains { $0.id == candidate.id } }) { take in
                    Button {
                        state.invalidatePlaybackIntent(); if active { player.pause() }
                        state.selectedJobID = take.id; state.showingSelection = false; sheet = nil
                    } label: {
                        VStack(alignment: .leading) {
                            Text(take.createdAt ?? "Imported recording")
                            Text(state.readyIDs.contains(take.id) ? "Ready offline" : take.status == "completed" ? "On PC · download in Manage audiobook" : take.status.capitalized).font(.caption)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("reader.recording." + take.id)
                }
            }
        case .speed, .sleep:
            List {
                if case .speed = choice {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { player.rate = rate; sheet = nil }.frame(minHeight: 44) }
                } else {
                    ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                        Button(minutes == 0 ? "Off" : "\(minutes) min") { player.sleep(minutes: minutes == 0 ? nil : minutes); sheet = nil }
                            .frame(minHeight: 44).accessibilityLabel(minutes == 0 ? "Off" : "\(minutes) minutes")
                    }
                }
            }
        }
    }
    private func control(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 24)).frame(width: 44, height: 44).background(Obsidian.background).contentShape(.rect) }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier("reader.player." + id)
    }
    private func clock(_ seconds: Double) -> String { Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond)) }
    private func selectScope(_ scope: NarrationScope) {
        guard !state.working, !discovering, !reader.capturingScope else { return }
        state.invalidatePlaybackIntent(); if active { player.pause() }
        state.savedJobID = nil; state.selectedJobID = nil; state.showingSelection = false
        state.playbackScope = scope; refreshLocal()
    }
    private func seek(_ seconds: Double) {
        state.invalidatePlaybackIntent()
        if !active, let job, let selection = state.selection { playDownloaded(job, selection: selection, autoplay: false) }
        if active { player.seek(seconds); reader.connectPlayback(player) }
    }
    private func skip(_ seconds: Double) {
        if state.mode == .device { if active { player.skip(seconds) }; return }
        seek(max(0, (active ? player.elapsed : 0) + seconds))
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
                            sheet = nil
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
                if chapterGroups.isEmpty { Text("No downloaded chapters for this narrator. Open Manage audiobook to set up chapter audio.") }
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
        sheet = .chapters(chapterGroups)
    }
    private func selectChapter(_ take: DownloadedChapterTake) {
        guard let job = companion.jobs.first(where: { $0.id == take.jobID }), ReaderTakeMatch.mode(job) == state.mode,
              let remote = companion.books.first(where: { $0.id == job.bookId }), remote.sourceSha256 == reader.book?.sourceSHA256 else { return }
        state.invalidatePlaybackIntent()
        companion.play(take.firstRecord, library: library, player: player, fromBeginning: true)
        guard player.isPlaying else { state.error = player.error; return }
        state.remote = remote; state.selectedJobID = job.id; state.readyIDs.insert(job.id)
        state.snapshot = nil
        let chapter = remote.chapters.first(where: { $0.segments.contains { $0.id == take.firstRecord.asset.segmentId } })
        state.selection = ReaderAudioCatalog.selection(job: job, book: remote, chapter: chapter)
        state.playbackScope = take.scope == "Full chapter" ? .chapter : .page
        state.savedJobID = state.playbackScope == .page ? job.id : nil
        reader.connectPlayback(player); sheet = nil
    }
    private func select(_ mode: ReaderVoiceMode) {
        state.invalidatePlaybackIntent()
        if active && state.mode != mode { player.pause() }
        state.mode = mode; state.error = nil; state.captureError = nil; state.needsCast = false; state.showingSelection = false; state.voice = nil; state.selectedJobID = nil; state.savedJobID = nil
        if mode != .device { refreshLocal() }
    }

    private func refreshLocal() {
        guard !discovering else { pendingDiscovery = true; return }
        discovering = true
        // Keep the selected recording's clock intact during exact-source lookup.
        // canPlay remains disabled until discovery resolves the new source.
        Task {
            defer {
                discovering = false
                if pendingDiscovery { pendingDiscovery = false; refreshLocal() }
            }
            do { let snapshot = try await reader.captureScope(state.playbackScope); if let local = reader.book { state.discover(snapshot: snapshot, local: local, companion: companion) } }
            catch { state.captureError = error.localizedDescription; state.readyIDs = []; state.selectedJobID = nil }
        }
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
    private func playDownloaded(_ job: RemoteJob, selection: ReaderSourceSelection, autoplay: Bool = true) {
        let recording: DownloadedRecordingSelection
        do { recording = try DownloadedRecordingSelection.reader(job: job, selection: selection, records: companion.orderedDownloads(jobID: job.id)) }
        catch { state.error = error.localizedDescription; return }
        companion.playRecording(recording, library: library, player: player, fromBeginning: true, autoplay: autoplay, scope: state.playbackScope == .page ? "Page" : "Chapter")
        guard player.recordingID == recording.id else { state.error = player.error; state.readyIDs.remove(job.id); return }
        reader.connectPlayback(player)
    }

}
