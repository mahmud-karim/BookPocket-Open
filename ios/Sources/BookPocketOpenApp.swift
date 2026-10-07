import SwiftUI

@main struct BookPocketOpenApp: App {
    @State private var library: LibraryStore
    @State private var player = PlaybackController()
    @State private var companion: CompanionStore
    @State private var selectedTab = "library"
    @AppStorage("appTheme") private var theme = "dark"
    @Environment(\.scenePhase) private var scenePhase
    @State private var restoredListening = false
    #if DEBUG
    @State private var installedTransportFixture = false
    #endif
    init() {
        #if DEBUG
        if UITestManageAudiobookFixture.enabled {
            let sessionID = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--manage-persistence-id=") }?.split(separator: "=").last.map(String.init)
            let root = URL.documentsDirectory.appendingPathComponent("ManageAudiobookUITest-" + (sessionID ?? UUID().uuidString))
            _library = State(initialValue: LibraryStore(root: root.appendingPathComponent("Library")))
            do { _companion = State(initialValue: try UITestManageAudiobookFixture.store(root: root.appendingPathComponent("Companion"))) }
            catch { fatalError("Isolated audiobook management fixture failed: \(error)") }
            return
        }
        if UITestCastReviewFixture.enabled {
            let sessionID = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--review-persistence-id=") }?.split(separator: "=").last.map(String.init)
            let root = URL.documentsDirectory.appendingPathComponent("CastReviewUITest-" + (sessionID ?? UUID().uuidString))
            _library = State(initialValue: LibraryStore(root: root.appendingPathComponent("Library")))
            do { _companion = State(initialValue: try UITestCastReviewFixture.store(root: root.appendingPathComponent("Companion"))) }
            catch { fatalError("Isolated cast review fixture failed: \(error)") }
            return
        }
        if UITestConnectionFixture.enabled {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectionUITest-" + UUID().uuidString)
            _library = State(initialValue: LibraryStore(root: root.appendingPathComponent("Library")))
            do { _companion = State(initialValue: try UITestConnectionFixture.store(root: root.appendingPathComponent("Companion"))) }
            catch { fatalError("Isolated connection UI fixture failed: \(error)") }
            _selectedTab = State(initialValue: "connection")
            return
        }
        if UITestTransportFixture.enabled {
            // A fresh isolated store prevents existing pairing credentials or
            // personal downloads from entering the offline transport test.
            let sessionID = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--transport-persistence-id=") }?.split(separator: "=").last.map(String.init)
            let root = URL.documentsDirectory.appendingPathComponent("TransportUITest-" + (sessionID ?? UUID().uuidString))
            _library = State(initialValue: LibraryStore(root: root.appendingPathComponent("Library")))
            _companion = State(initialValue: CompanionStore(root: root.appendingPathComponent("Companion")))
            return
        }
        #endif
        _library = State(initialValue: LibraryStore())
        _companion = State(initialValue: CompanionStore())
    }
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
                Tab("Connection", systemImage: "desktopcomputer", value: "connection") {
                    ConnectionView().safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                }
            }
            .tint(Obsidian.accent)
            .preferredColorScheme(theme == "system" ? nil : theme == "light" ? .light : .dark)
            .environment(library).environment(player).environment(companion)
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--content-size-probe") {
                    UITestContentSizeProbe().frame(width: 1, height: 1).allowsHitTesting(false)
                }
                #endif
            }
            .task {
                #if DEBUG
                if UITestManageAudiobookFixture.enabled && !installedTransportFixture {
                    installedTransportFixture = true
                    do {
                        if library.books.isEmpty { try await UITestManageAudiobookFixture.install(library: library, companion: companion) }
                        else { await companion.refresh() }
                    } catch { library.error = error.localizedDescription }
                }
                if UITestCastReviewFixture.enabled && !installedTransportFixture {
                    installedTransportFixture = true
                    do {
                        if library.books.isEmpty { try await UITestCastReviewFixture.install(library: library, companion: companion) }
                        else { await companion.refresh() }
                    } catch { library.error = error.localizedDescription }
                }
                if UITestTransportFixture.enabled && !installedTransportFixture {
                    installedTransportFixture = true
                    do {
                        if library.books.isEmpty { try await UITestTransportFixture.install(library: library, companion: companion); try companion.persistTransportFixture() }
                        selectedTab = "listen"
                    }
                    catch { library.error = error.localizedDescription }
                }
                #endif
                if !restoredListening {
                    restoredListening = true
                    player.onSessionUpdate = { [weak companion, weak player] force in if let player { companion?.captureListeningSession(player, force: force) } }
                    await companion.restoreListeningSession(library: library, player: player)
                }
            }
            .onChange(of: scenePhase) { if scenePhase != .active { companion.captureListeningSession(player) } }
            .onOpenURL { url in Task { do { try await library.importBook(url) } catch { library.error = error.localizedDescription } } }
            .alert("Book Pocket Open", isPresented: Binding(get: { library.error != nil || player.error != nil }, set: { if !$0 { library.error = nil; player.error = nil } })) { Button("OK") { library.error = nil; player.error = nil } } message: { Text(library.error ?? player.error ?? "") }
        }
    }

    // Inset each tab's content, whose safe area already excludes the native tab bar.
    // Insetting the entire TabView can replace/cover that bar while narration exists.
    @ViewBuilder private var miniPlayer: some View {
        if player.bookID != nil && !player.miniPlayerDismissed {
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
                Button { player.toggle() } label: {
                    Label(player.isPlaying ? "Pause narration" : "Resume narration", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }
                    .accessibilityIdentifier("player.mini.toggle")
                    .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
                Button { player.dismissMiniPlayer() } label: {
                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }.accessibilityLabel("Close player").accessibilityIdentifier("player.mini.close")
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(Obsidian.surface).overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("player.mini")
        }
    }
}
