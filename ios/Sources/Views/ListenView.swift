import SwiftUI

struct ListenView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(CompanionStore.self) private var companion
    @State private var removingJob: String?
    var body: some View {
        @Bindable var player = player
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if let id = player.bookID, let book = library.book(id) {
                        BookCover(book: book, url: library.cover(book)).frame(maxWidth: 240).padding(.top, 20).shadow(color: .black.opacity(0.2), radius: 24, y: 16)
                        VStack(spacing: 8) { Text(player.title).font(.system(.title, design: .serif)).multilineTextAlignment(.center); Text(player.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                        if player.duration > 0 {
                            Slider(value: Binding(get: { player.elapsed }, set: { player.seek($0) }), in: 0...max(1, player.duration)).accessibilityLabel("Audio position")
                            HStack { Text(Duration.seconds(player.elapsed).formatted(.time(pattern: .minuteSecond))); Spacer(); Text(Duration.seconds(player.duration).formatted(.time(pattern: .minuteSecond))) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 42) {
                            Button("Back 15 seconds or previous sentence", systemImage: "gobackward.15") { player.skip(-15) }.font(.title)
                            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }.font(.largeTitle).frame(width: 78, height: 78).background(Obsidian.accent.opacity(0.16), in: .circle)
                            Button("Forward 15 seconds or next sentence", systemImage: "goforward.15") { player.skip(15) }.font(.title)
                        }.labelStyle(.iconOnly)
                        HStack {
                            Menu { ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in Button("\(value.formatted())×") { player.rate = value } } } label: { Text("\(player.rate.formatted())×").font(.headline) }.accessibilityLabel("Playback speed")
                            Spacer()
                            Menu { Button("Off") { player.sleep(minutes: nil) }; ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) minutes") { player.sleep(minutes: minutes) } } } label: { Label(player.sleepUntil == nil ? "Sleep timer" : "Timer set", systemImage: "moon") }
                        }.padding(.horizontal, 20)
                        if let current = companion.downloads.first(where: { $0.id == book.audioAssetID }), let remote = companion.books.first(where: { $0.id == companion.jobs.first(where: { $0.id == current.jobID })?.bookId }) {
                            Menu("Chapters", systemImage: "list.bullet") {
                                ForEach(remote.chapters) { chapter in
                                    if let record = companion.orderedDownloads(jobID: current.jobID).first(where: { record in chapter.segments.contains { $0.id == record.asset.segmentId } }) {
                                        Button(chapter.title) { companion.play(record, library: library, player: player) }
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("Your next listening chapter", systemImage: "headphones", description: Text("Open a book and choose Read aloud. Generated narration downloaded from your PC also plays here."))
                    }
                    if !companion.downloads.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Downloaded narration").font(.title2.bold())
                            ForEach(Array(Set(companion.downloads.map(\.jobID))).sorted(), id: \.self) { jobID in
                                if let first = companion.orderedDownloads(jobID: jobID).first, let book = library.book(first.localBookID) {
                                    Button { if let record = companion.resumeRecord(jobID: jobID, library: library) { companion.play(record, library: library, player: player) } } label: {
                                        HStack(spacing: 14) {
                                            BookCover(book: book, url: library.cover(book)).frame(width: 46)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(first.legacyTitle ?? book.title).font(.headline).foregroundStyle(.primary)
                                                Text(first.legacyTitle != nil ? "Legacy audio · no synchronized text" : companion.takeDescription(jobID: jobID)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(); Image(systemName: "play.circle").font(.title2)
                                        }
                                    }.buttonStyle(.plain).contextMenu { Button("Remove download", systemImage: "trash", role: .destructive) { removingJob = jobID } }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                    }
                }.padding(28)
            }.background(Obsidian.background).navigationTitle("Listen")
            .confirmationDialog("Remove this take from your device? The PC copy is kept.", isPresented: Binding(get: { removingJob != nil }, set: { if !$0 { removingJob = nil } }), titleVisibility: .visible) {
                Button("Remove download", role: .destructive) {
                    if let removingJob {
                        if companion.downloads.contains(where: { $0.jobID == removingJob && $0.localBookID == player.bookID }) { player.stop() }
                        do { try companion.removeDownloadedTake(removingJob) } catch { companion.error = error.localizedDescription }
                    }
                    removingJob = nil
                }
            }
        }
    }
}
