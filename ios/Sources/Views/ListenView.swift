import SwiftUI

struct ListenView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDownloads = false
    @State private var chapterPresentation: ChapterPresentation?
    private struct ChapterPresentation: Identifiable {
        let id = UUID()
        let groups: [DownloadedChapterGroup]
    }
    private var hasBookDownloads: Bool {
        companion.downloads.contains { $0.localBookID == player.bookID }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if let id = player.bookID, let book = library.book(id) {
                    let landscape = geometry.size.width > geometry.size.height
                    let compact = geometry.size.height < 600 || dynamicTypeSize.isAccessibilitySize
                    Group {
                        if landscape {
                            HStack(spacing: 28) {
                                VStack(spacing: 8) {
                                    artwork(book, height: dynamicTypeSize.isAccessibilitySize ? 0 : max(0, min(120, geometry.size.height - 152)))
                                    heading(compact: true)
                                    chaptersButton
                                }.frame(maxWidth: .infinity)
                                VStack(spacing: 12) { timeline; transport(compact: true); settings }.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: compact ? 10 : 16) {
                                Spacer(minLength: 0).layoutPriority(-2)
                                artwork(book, height: dynamicTypeSize.isAccessibilitySize ? 0 : max(0, min(250, geometry.size.height - 390)))
                                heading(compact: compact)
                                chaptersButton
                                timeline
                                transport(compact: compact)
                                settings
                                Spacer(minLength: 0).layoutPriority(-2)
                            }
                        }
                    }.padding(.horizontal, landscape ? 28 : 24).padding(.vertical, 12)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ContentUnavailableView("Your next listening chapter", systemImage: "headphones", description: Text("Open a book and choose Read aloud, or choose a downloaded narration from the tray above."))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }.background(Obsidian.background).navigationTitle("Listen").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("Downloaded narration", systemImage: "tray.full") { showDownloads = true }.accessibilityIdentifier("listen.downloads")
                } }
                .sheet(isPresented: $showDownloads) { DownloadedNarrationView() }
                .sheet(item: $chapterPresentation) { presentation in chapters(presentation.groups) }
        }
    }
    @ViewBuilder private func artwork(_ book: LocalBook, height: CGFloat) -> some View {
        if height >= 48 {
            BookCover(book: book, url: library.cover(book)).frame(maxWidth: height * 0.68, maxHeight: height)
                .layoutPriority(-1).shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        }
    }
    private func heading(compact: Bool) -> some View {
        VStack(spacing: 4) {
            Text(player.title).font(.system(compact ? .title3 : .title2, design: .serif)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            Text(player.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var chaptersButton: some View {
        Button {
            let groups = player.bookID.flatMap { library.book($0) }.map { companion.downloadedChapterGroups(for: $0) } ?? []
            // Publish the snapshot and presentation together. Separate state
            // writes can present the sheet with its previous empty snapshot.
            chapterPresentation = ChapterPresentation(groups: groups)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet")
                Text(player.chapterTitle.isEmpty ? "Choose chapter" : player.chapterTitle).lineLimit(1)
                Spacer(minLength: 8); Image(systemName: "chevron.down").font(.caption)
            }.font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                .background(Obsidian.surface, in: .rect(cornerRadius: 12))
        }.buttonStyle(.plain).foregroundStyle(Obsidian.accent)
            .disabled(player.speechChapters.isEmpty && !hasBookDownloads)
            .accessibilityLabel("Chapters").accessibilityValue(player.chapterTitle).accessibilityIdentifier("listen.chapters")
    }
    @ViewBuilder private var timeline: some View {
        if player.duration > 0 {
            VStack(spacing: 0) {
                Slider(value: Binding(get: { player.elapsed }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                    .accessibilityLabel("Audio position").accessibilityIdentifier("listen.position")
                HStack {
                    Text(Duration.seconds(player.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .accessibilityIdentifier("listen.elapsed")
                    Spacer()
                    Text(Duration.seconds(player.duration).formatted(.time(pattern: .minuteSecond)))
                        .accessibilityIdentifier("listen.duration")
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else { Text(player.isPlaying ? "Reading aloud" : "Ready when you are").font(.caption).foregroundStyle(.secondary) }
    }
    private func transport(compact: Bool) -> some View {
        HStack(spacing: compact ? 30 : 42) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.title2).frame(width: 44, height: 44).contentShape(.rect)
            }.accessibilityLabel("Back 15 seconds or previous sentence").accessibilityIdentifier("listen.backward")
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                .font(.system(size: compact ? 26 : 30)).frame(width: compact ? 64 : 76, height: compact ? 64 : 76)
                .background(Obsidian.accent.opacity(0.16), in: .circle)
                .accessibilityIdentifier("player.full.toggle").accessibilityValue(player.isPlaying ? "Playing" : "Paused")
            Button { player.skip(15) } label: {
                Image(systemName: "goforward.15").font(.title2).frame(width: 44, height: 44).contentShape(.rect)
            }.accessibilityLabel("Forward 15 seconds or next sentence").accessibilityIdentifier("listen.forward")
        }.labelStyle(.iconOnly)
    }
    private var settings: some View {
        HStack {
            Menu { ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in Button("\(value.formatted())×") { player.rate = value } } } label: {
                Text("\(player.rate.formatted())×").font(.headline).lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 64, minHeight: 44)
            }.accessibilityLabel("Playback speed").accessibilityValue("\(player.rate.formatted())×").accessibilityIdentifier("listen.speed")
            Spacer()
            Menu {
                Button("Off") { player.sleep(minutes: nil) }
                ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) minutes") { player.sleep(minutes: minutes) } }
            } label: { Label(player.sleepUntil == nil ? "Sleep timer" : "Timer set", systemImage: "moon").font(.subheadline).lineLimit(1).minimumScaleFactor(0.6).frame(minHeight: 44) }
                .accessibilityIdentifier("listen.sleep")
        }
    }
    private func chapters(_ audioChapters: [DownloadedChapterGroup]) -> some View {
        NavigationStack {
            List {
                if !player.speechChapters.isEmpty {
                    Section {
                        ForEach(Array(player.speechChapters.enumerated()), id: \.offset) { index, chapter in
                            Button(chapter.title ?? "Chapter \(index + 1)") {
                                Task {
                                    if await player.selectSpeechChapter(chapter) {
                                        if let id = player.bookID, let locator = player.speechLocator { library.saveLocation(id, locator: locator) }
                                        chapterPresentation = nil
                                    }
                                }
                            }
                                .accessibilityIdentifier("listen.chapter.\(index)")
                        }
                    } footer: { Text("Starts on-device narration at the selected chapter.") }
                } else {
                    ForEach(audioChapters) { chapter in
                        Section(chapter.title) {
                            ForEach(chapter.takes) { take in
                                Button {
                                    companion.play(take.firstRecord, library: library, player: player, fromBeginning: true)
                                    if player.isPlaying { chapterPresentation = nil }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(take.scope).font(.headline)
                                            Text(take.description).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if isCurrentTake(take) { Image(systemName: "checkmark").accessibilityLabel("Current take") }
                                    }
                                }.accessibilityLabel("\(take.scope), \(take.description)" + (isCurrentTake(take) ? ", Current take" : ""))
                                    .accessibilityIdentifier("listen.chapter.\(take.id)")
                            }
                        }
                    }
                    Section {
                        if audioChapters.isEmpty { Text("No chapter audio is available on this device.").foregroundStyle(.secondary) }
                    } footer: { Text("Choose a downloaded take for any chapter. Excerpts contain only part of a chapter. Playback continues within the selected take; it never switches to another take automatically.") }
                }
            }.navigationTitle("Chapters").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { chapterPresentation = nil } } }
        }.tint(Obsidian.accent)
    }
    private func isCurrentTake(_ take: DownloadedChapterTake) -> Bool {
        guard let id = player.bookID, let current = library.book(id)?.audioAssetID else { return false }
        return take.recordIDs.contains(current)
    }
}

private struct DownloadedNarrationView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var removingJob: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(Set(companion.downloads.map(\.jobID))).sorted(), id: \.self) { jobID in
                    if let first = companion.orderedDownloads(jobID: jobID).first, let book = library.book(first.localBookID) {
                        Button {
                            if let record = companion.resumeRecord(jobID: jobID, library: library) {
                                companion.play(record, library: library, player: player)
                                if player.isPlaying { dismiss() }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                BookCover(book: book, url: library.cover(book)).frame(width: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(first.legacyTitle ?? book.title).font(.headline).foregroundStyle(.primary)
                                    Text(first.legacyTitle != nil ? "Legacy audio · no synchronized text" : companion.takeDescription(jobID: jobID)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "play.circle").font(.title2)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("listen.download.\(jobID)")
                            .swipeActions { Button("Remove", systemImage: "trash", role: .destructive) { removingJob = jobID } }
                            .contextMenu { Button("Remove download", systemImage: "trash", role: .destructive) { removingJob = jobID } }
                    }
                }
            }.overlay { if companion.downloads.isEmpty { ContentUnavailableView("No downloaded narration", systemImage: "tray", description: Text("Download a completed narration from your reader or Studio.")) } }
                .navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Remove this take from your device? The PC copy is kept.", isPresented: Binding(get: { removingJob != nil }, set: { if !$0 { removingJob = nil } }), titleVisibility: .visible) {
                    Button("Remove download", role: .destructive) {
                        if let removingJob {
                            if companion.downloads.contains(where: { $0.jobID == removingJob && $0.localBookID == player.bookID }) { player.stop() }
                            do { try companion.removeDownloadedTake(removingJob) } catch { companion.error = error.localizedDescription }
                        }
                        removingJob = nil
                    }
                }
        }.tint(Obsidian.accent)
    }
}
