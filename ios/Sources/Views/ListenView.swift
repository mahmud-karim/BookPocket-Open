import SwiftUI

struct ListenView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(LibraryStore.self) private var library
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
                    } else {
                        ContentUnavailableView("Your next listening chapter", systemImage: "headphones", description: Text("Open a book and choose Read aloud. Generated narration downloaded from your PC also plays here."))
                    }
                }.padding(28)
            }.background(Obsidian.background).navigationTitle("Listen")
        }
    }
}
