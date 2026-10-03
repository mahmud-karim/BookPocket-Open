import SwiftUI
import ReadiumNavigator
import ReadiumShared
import AVFoundation

struct NativeReader: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let onHighlight: () -> Void
    func makeUIViewController(context: Context) -> ReaderContainer { ReaderContainer(navigator: navigator, onHighlight: onHighlight) }
    func updateUIViewController(_ controller: ReaderContainer, context: Context) {}
}

final class ReaderContainer: UIViewController {
    let navigator: EPUBNavigatorViewController
    let onHighlight: () -> Void
    init(navigator: EPUBNavigatorViewController, onHighlight: @escaping () -> Void) { self.navigator = navigator; self.onHighlight = onHighlight; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); addChild(navigator); view.addSubview(navigator.view)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), navigator.view.topAnchor.constraint(equalTo: view.topAnchor), navigator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        navigator.didMove(toParent: self)
    }
    @objc func highlightSelection(_ sender: Any?) { onHighlight() }
}

struct ReaderView: View {
    @State var model: ReaderModel
    @Environment(PlaybackController.self) private var player
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var panel: ReaderPanel?
    @State private var query = ""
    @State private var narration: ReaderNarrationPresentation?
    @AppStorage("readerFontSize") private var fontSize = 110.0
    @AppStorage("readerScroll") private var scroll = false
    @AppStorage("readerTheme") private var theme = "cream"
    @AppStorage("speechVoice") private var speechVoice = ""
    private enum ReaderPanel: String, Identifiable { case contents, search, annotations, appearance; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            Group {
                if let navigator = model.navigator { NativeReader(navigator: navigator, onHighlight: { model.addAnnotation(highlight: true) }).accessibilityIdentifier("reader.publication") }
                else if model.loading { ProgressView("Opening book…") }
                else { ContentUnavailableView("Unable to open book", systemImage: "book.closed", description: Text(model.error ?? "Try importing the book again.")) }
            }
            .navigationTitle(model.book?.title ?? "Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Library", systemImage: "chevron.down") { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("reader.close") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Contents", systemImage: "list.bullet") { panel = .contents }.labelStyle(.iconOnly).accessibilityIdentifier("reader.contents")
                    Menu {
                        Button("Generate current page", systemImage: "doc.text") { captureNarration(.page) }.accessibilityIdentifier("reader.generate.page")
                        Button("Generate current chapter", systemImage: "book") { captureNarration(.chapter) }.accessibilityIdentifier("reader.generate.chapter")
                        if let recent = companion.jobs.first(where: { job in
                            job.sourceRanges?.isEmpty == false && companion.books.contains(where: { $0.id == job.bookId && $0.sourceSha256 == model.book?.sourceSHA256 })
                        }) { Button("Recent narration", systemImage: "clock") { narration = ReaderNarrationPresentation(jobID: recent.id) } }
                        Button("Use on-device voice", systemImage: "speaker.wave.2") { speakOnDevice() }
                    } label: { Label(model.capturingScope ? "Capturing text…" : "Generate narration", systemImage: "waveform.badge.plus") }
                    .disabled(model.capturingScope || model.navigator == nil).accessibilityIdentifier("reader.generate")
                    Menu {
                        Button("Search book", systemImage: "magnifyingglass") { panel = .search }
                        Button("Add bookmark", systemImage: "bookmark") { model.addAnnotation(highlight: false) }
                        Button("Highlight selection", systemImage: "highlighter") { model.addAnnotation(highlight: true) }
                        Button("Bookmarks & highlights", systemImage: "bookmark.square") { panel = .annotations }
                        Button("Reading appearance", systemImage: "textformat.size") { panel = .appearance }
                    } label: { Label("Reader options", systemImage: "ellipsis.circle") }.accessibilityIdentifier("reader.options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button("Previous page", systemImage: "chevron.left") { Task { await model.navigator?.goBackward() } }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                    Spacer()
                    Button {
                        if player.bookID == model.bookID { player.toggle(); model.connectPlayback(player) }
                        else { speakOnDevice() }
                    } label: { Label(player.isPlaying && player.bookID == model.bookID ? "Pause" : player.bookID == model.bookID ? "Resume" : "Read aloud", systemImage: player.isPlaying && player.bookID == model.bookID ? "pause.fill" : "headphones") }
                    .accessibilityIdentifier("reader.speak")
                    Spacer()
                    Button("Next page", systemImage: "chevron.right") { Task { await model.navigator?.goForward() } }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.padding(.horizontal).background(Obsidian.surface)
            }
            .task { await model.load(); if player.bookID == model.bookID { model.connectPlayback(player); if let locator = player.speechLocator { model.follow(locator) } } }
            .sheet(item: $panel) { selected in
                NavigationStack {
                    panelView(selected).navigationTitle(selected.rawValue.capitalized).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(item: $narration) { presentation in ReaderNarrationView(presentation: presentation, reader: model) }
            .alert("Reader", isPresented: Binding(get: { model.error != nil && !model.loading && model.navigator != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }.tint(Obsidian.accent)
    }
    private func speakOnDevice() {
        guard let publication = model.publication, let book = model.book else { return }
        player.speak(publication: publication, book: book, from: model.navigator?.currentLocation); model.connectPlayback(player)
    }
    private func captureNarration(_ scope: NarrationScope) {
        Task { do { narration = ReaderNarrationPresentation(snapshot: try await model.captureScope(scope)) } catch { model.error = error.localizedDescription } }
    }
    @ViewBuilder private func panelView(_ selected: ReaderPanel) -> some View {
        switch selected {
        case .contents:
            List {
                ForEach(Array(flatten(model.chapters).enumerated()), id: \.offset) { _, link in
                    Button(link.title ?? link.href) { Task { await model.navigator?.go(to: link); panel = nil } }
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
            }.onChange(of: fontSize) { model.applyPreferences() }.onChange(of: theme) { model.applyPreferences() }.onChange(of: scroll) { model.applyPreferences() }
        }
    }
    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
}
