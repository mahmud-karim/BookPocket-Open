import SwiftUI
import ReadiumNavigator
import ReadiumShared
import AVFoundation

struct NativeReader: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let onHighlight: () -> Void
    let onPronunciation: () -> Void
    func makeUIViewController(context: Context) -> ReaderContainer { ReaderContainer(navigator: navigator, onHighlight: onHighlight, onPronunciation: onPronunciation) }
    func updateUIViewController(_ controller: ReaderContainer, context: Context) {}
}

final class ReaderContainer: UIViewController {
    let navigator: EPUBNavigatorViewController
    let onHighlight: () -> Void
    let onPronunciation: () -> Void
    init(navigator: EPUBNavigatorViewController, onHighlight: @escaping () -> Void, onPronunciation: @escaping () -> Void) { self.navigator = navigator; self.onHighlight = onHighlight; self.onPronunciation = onPronunciation; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); addChild(navigator); view.addSubview(navigator.view)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), navigator.view.topAnchor.constraint(equalTo: view.topAnchor), navigator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        navigator.didMove(toParent: self)
    }
    @objc func highlightSelection(_ sender: Any?) { onHighlight() }
    @objc func pronounceSelection(_ sender: Any?) { onPronunciation() }
}

struct ReaderView: View {
    @State var model: ReaderModel
    @Environment(PlaybackController.self) private var player
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var panel: ReaderPanel?
    @State private var query = ""
    @State private var contentsError: String?
    @State private var showPlayer = false
    @State private var audiobookSetup: AudiobookSetupRequest?
    @State private var pronunciationSelection: PronunciationSelection?
    private struct PronunciationSelection: Identifiable { var id = UUID(); var text: String }
    @AppStorage("readerFontSize") private var fontSize = 110.0
    @AppStorage("readerScroll") private var scroll = false
    @AppStorage("readerTheme") private var theme = "cream"
    @AppStorage("speechVoice") private var speechVoice = ""
    private enum ReaderPanel: String, Identifiable { case contents, search, annotations, appearance; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            Group {
                if let navigator = model.navigator { NativeReader(navigator: navigator, onHighlight: { model.addAnnotation(highlight: true) }, onPronunciation: openPronunciation).accessibilityIdentifier("reader.publication") }
                else if model.loading { ProgressView("Opening book…") }
                else { ContentUnavailableView("Unable to open book", systemImage: "book.closed", description: Text(model.error ?? "Try importing the book again.")) }
            }
            .navigationTitle(model.book?.title ?? "Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Library", systemImage: "chevron.down") { companion.readerPlayer(for: model.bookID).invalidatePlaybackIntent(); dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("reader.close") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Contents", systemImage: "list.bullet") { contentsError = nil; panel = .contents }.labelStyle(.iconOnly).disabled(!model.pageReady).accessibilityIdentifier("reader.contents")
                    Menu {
                        Button("Search book", systemImage: "magnifyingglass") { panel = .search }
                        Button("Add bookmark", systemImage: "bookmark") { model.addAnnotation(highlight: false) }
                        Button("Highlight selection", systemImage: "highlighter") { model.addAnnotation(highlight: true) }
                        Button("Bookmarks & highlights", systemImage: "bookmark.square") { panel = .annotations }
                        Button("Manage audiobook", systemImage: "waveform") { openAudiobookSetup() }.accessibilityIdentifier("reader.manageAudiobook")
                        Button("Reading appearance", systemImage: "textformat.size") { panel = .appearance }
                        Button("Pronunciation", systemImage: "text.bubble") { openPronunciation() }.accessibilityIdentifier("reader.pronunciation")
                    } label: { Label("Reader options", systemImage: "ellipsis.circle") }.accessibilityIdentifier("reader.options")
                }
            }
            .toolbarBackground(readerPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme == "dark" ? .dark : .light, for: .navigationBar)
            .background(readerPaper.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button { Task { await model.navigator?.goBackward() } } label: {
                        Label("Previous page", systemImage: "chevron.left").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }.accessibilityIdentifier("reader.previous")
                    Spacer()
                    Button { openPlayer() } label: {
                        Group {
                            if dynamicTypeSize.isAccessibilitySize { Label("Read aloud", systemImage: "headphones").labelStyle(.iconOnly) }
                            else { Label("Read aloud", systemImage: "headphones") }
                        }.frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }
                    .accessibilityIdentifier("reader.speak")
                    .disabled(!model.pageReady)
                    Spacer()
                    Button { Task { await model.navigator?.goForward() } } label: {
                        Label("Next page", systemImage: "chevron.right").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }.accessibilityIdentifier("reader.next")
                }.padding(.horizontal).background(Obsidian.surface)
            }
            .task { await model.load(); if player.bookID == model.bookID { model.connectPlayback(player); if let locator = player.speechLocator { model.follow(locator) } } }
            .sheet(item: $panel) { selected in
                NavigationStack {
                    panelView(selected).navigationTitle(selected.rawValue.capitalized).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: Binding(get: { showPlayer && dynamicTypeSize.isAccessibilitySize }, set: { if !$0 { closePlayer() } }), onDismiss: { companion.readerPlayer(for: model.bookID).invalidatePlaybackIntent() }) {
                ReaderPlayerView(reader: model, state: companion.readerPlayer(for: model.bookID), onClose: closePlayer, onManage: openAudiobookSetup)
                    .interactiveDismissDisabled()
                    .sheet(item: $audiobookSetup, onDismiss: { openPlayer() }) { request in
                        AudiobookSetupView(request: request, reader: model, state: companion.readerPlayer(for: model.bookID))
                    }
            }
            .sheet(item: Binding(get: { dynamicTypeSize.isAccessibilitySize && showPlayer ? nil : audiobookSetup }, set: { audiobookSetup = $0 }), onDismiss: { if showPlayer { openPlayer() } }) { request in
                AudiobookSetupView(request: request, reader: model, state: companion.readerPlayer(for: model.bookID))
            }
            .sheet(item: $pronunciationSelection) { selection in
                PronunciationEditorView(selectedText: selection.text, language: model.book?.language ?? "en", onRegenerate: {
                    let state = companion.readerPlayer(for: model.bookID)
                    if state.mode == .device { state.mode = .kyon }
                    state.requestGenerationChoice = true; openAudiobookSetup()
                })
            }
            .alert("Reader", isPresented: Binding(get: { model.error != nil && !model.loading && model.navigator != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }.tint(theme == "dark" ? .white : .black).preferredColorScheme(theme == "dark" ? .dark : .light)
            .onChange(of: fontSize) { model.applyPreferences(theme: theme, fontSize: fontSize, scroll: scroll) }
            .onChange(of: theme) { model.applyPreferences(theme: theme, fontSize: fontSize, scroll: scroll) }
            .onChange(of: scroll) { model.applyPreferences(theme: theme, fontSize: fontSize, scroll: scroll) }
            .overlay(alignment: .bottom) {
                if showPlayer && !dynamicTypeSize.isAccessibilitySize {
                    // An overlay preserves the Readium viewport and exact page
                    // capture. It has no floating UISheet transform or hit path.
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            ReaderPlayerView(reader: model, state: companion.readerPlayer(for: model.bookID), onClose: closePlayer, onManage: openAudiobookSetup)
                                .frame(height: min(530, geometry.size.height))
                                .environment(\.colorScheme, .dark)
                                .clipShape(.rect(topLeadingRadius: 24, topTrailingRadius: 24))
                                .shadow(color: .black.opacity(0.25), radius: 14, y: -4)
                        }
                    }.ignoresSafeArea(.container, edges: .bottom)
                }
            }
    }
    private var readerPaper: SwiftUI.Color { SwiftUI.Color(uiColor: ReaderPaperTheme.background(theme)) }
    private func openAudiobookSetup() {
        let state = companion.readerPlayer(for: model.bookID)
        Task {
            do {
                let snapshot = try await model.captureScope(state.playbackScope)
                let title = flatten(model.chapters).first { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href(snapshot.hrefs[snapshot.current.resource]) }?.title ?? model.location?.title ?? "Current chapter"
                if state.mode == .device { state.mode = .kyon }
                if let local = model.book, !state.working {
                    state.showingSelection = false; state.voice = nil; state.plan = []; state.needsCast = false
                    state.discover(snapshot: snapshot, local: local, companion: companion)
                }
                audiobookSetup = .init(bookID: model.bookID, chapterTitle: title, scope: state.playbackScope, mode: state.mode, snapshot: snapshot)
            } catch { state.captureError = error.localizedDescription; model.error = error.localizedDescription }
        }
    }
    private func closePlayer() {
        companion.readerPlayer(for: model.bookID).invalidatePlaybackIntent()
        showPlayer = false
    }
    private func openPronunciation() {
        pronunciationSelection = .init(text: model.navigator?.currentSelection?.locator.text.highlight ?? "")
        model.navigator?.clearSelection()
    }
    private func openPlayer() {
        let state = companion.readerPlayer(for: model.bookID)
        state.invalidatePlaybackIntent()
        Task {
            if !state.working && !state.showingSelection && state.mode != .device {
                do { let snapshot = try await model.captureScope(state.playbackScope); if let local = model.book { state.discover(snapshot: snapshot, local: local, companion: companion) } }
                catch { state.captureError = error.localizedDescription; state.readyIDs = [] }
            }
            showPlayer = true
        }
    }
    @ViewBuilder private func panelView(_ selected: ReaderPanel) -> some View {
        switch selected {
        case .contents:
            List {
                if let contentsError { Text(contentsError).foregroundStyle(.secondary) }
                ForEach(Array(flatten(model.chapters).enumerated()), id: \.offset) { _, link in
                    Button(link.title ?? link.href) { Task {
                        if await model.navigator?.go(to: link) == true { panel = nil }
                        else { contentsError = "This chapter isn't ready to open yet. Wait for the page to finish loading, then try again." }
                    } }
                }
            }
        case .search:
            List {
                if model.searching { ProgressView("Searching…") }
                ForEach(Array(model.searchResults.enumerated()), id: \.offset) { _, locator in
                    Button { Task { await model.navigator?.go(to: locator); panel = nil } } label: {
                        VStack(alignment: .leading, spacing: 6) { Text(locator.title ?? "Match").font(.caption).foregroundStyle(.secondary); Text((locator.text.before ?? "") + (locator.text.highlight ?? "") + (locator.text.after ?? "")).lineLimit(4) }
                    }
                }
            }.searchable(text: $query, prompt: "Search this book").onSubmit(of: .search) { Task { await model.search(query) } }
        case .annotations:
            List {
                if model.book?.annotations.isEmpty != false { Text("Save a bookmark or highlight a passage to find it here.").foregroundStyle(.secondary) }
                ForEach(model.book?.annotations ?? []) { annotation in
                    Button { if let locator = annotation.locator { Task { await model.navigator?.go(to: locator); panel = nil } } } label: {
                        Label(annotation.text, systemImage: annotation.kind == "highlight" ? "highlighter" : "bookmark").lineLimit(3)
                    }.swipeActions { Button("Delete", role: .destructive) { model.removeAnnotation(annotation) } }
                }
            }
        case .appearance:
            Form {
                Section("Reading") {
                    Slider(value: $fontSize, in: 75...200, step: 5) { Text("Text size") }
                    Picker("Page color", selection: $theme) { Text("Cream").tag("cream"); Text("Obsidian").tag("dark"); Text("White").tag("white") }.pickerStyle(.segmented)
                    Toggle("Continuous scrolling", isOn: $scroll)
                }
                Section("Read aloud") {
                    Picker("Voice", selection: $speechVoice) {
                        Text("System default").tag("")
                        ForEach(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: model.book?.language.prefix(2) ?? "en") && !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice) }, id: \.identifier) { voice in Text(voice.name).tag(voice.identifier) }
                    }
                    Text("Install additional voices in iOS Settings → Accessibility → Spoken Content.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
}
