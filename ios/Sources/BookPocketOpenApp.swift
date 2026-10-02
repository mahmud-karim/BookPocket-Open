import SwiftUI

@main struct BookPocketOpenApp: App {
    @State private var library = LibraryStore()
    @State private var player = PlaybackController()
    @State private var companion = CompanionStore()
    @AppStorage("appTheme") private var theme = "dark"
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Library", systemImage: "books.vertical") { LibraryView() }
                Tab("Listen", systemImage: "headphones") { ListenView() }
                Tab("Studio", systemImage: "waveform") { StudioView() }
            }
            .tint(Obsidian.accent)
            .preferredColorScheme(theme == "system" ? nil : theme == "light" ? .light : .dark)
            .environment(library).environment(player).environment(companion)
            .onOpenURL { url in Task { do { try await library.importBook(url) } catch { library.error = error.localizedDescription } } }
            .alert("Book Pocket Open", isPresented: Binding(get: { library.error != nil || player.error != nil }, set: { if !$0 { library.error = nil; player.error = nil } })) { Button("OK") { library.error = nil; player.error = nil } } message: { Text(library.error ?? player.error ?? "") }
        }
    }
}
