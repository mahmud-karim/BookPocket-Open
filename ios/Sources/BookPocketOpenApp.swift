import SwiftUI

@main struct BookPocketOpenApp: App {
    @State private var library = LibraryStore()
    @State private var player = PlaybackController()
    @State private var companion = CompanionStore()
    @State private var selectedTab = "library"
    @AppStorage("appTheme") private var theme = "dark"
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                Tab("Library", systemImage: "books.vertical", value: "library") {
                    LibraryView().safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                }
                Tab("Listen", systemImage: "headphones", value: "listen") { ListenView() }
                Tab("Studio", systemImage: "waveform", value: "studio") {
                    StudioView().safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                }
            }
            .tint(Obsidian.accent)
            .preferredColorScheme(theme == "system" ? nil : theme == "light" ? .light : .dark)
            .environment(library).environment(player).environment(companion)
            .onOpenURL { url in Task { do { try await library.importBook(url) } catch { library.error = error.localizedDescription } } }
            .alert("Book Pocket Open", isPresented: Binding(get: { library.error != nil || player.error != nil }, set: { if !$0 { library.error = nil; player.error = nil } })) { Button("OK") { library.error = nil; player.error = nil } } message: { Text(library.error ?? player.error ?? "") }
        }
    }

    // Inset each tab's content, whose safe area already excludes the native tab bar.
    // Insetting the entire TabView can replace/cover that bar while narration exists.
    @ViewBuilder private var miniPlayer: some View {
        if player.bookID != nil {
            HStack(spacing: 14) {
                Button { selectedTab = "listen" } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").foregroundStyle(Obsidian.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain).accessibilityLabel("Open player for \(player.title)")
                .accessibilityIdentifier("player.mini.open")
                Button(player.isPlaying ? "Pause narration" : "Resume narration", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("player.mini.toggle")
                    .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(Obsidian.surface).overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("player.mini")
        }
    }
}
