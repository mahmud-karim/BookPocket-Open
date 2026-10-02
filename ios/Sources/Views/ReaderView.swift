import SwiftUI
import ReadiumNavigator
import ReadiumShared
import AVFoundation

struct NativeReader: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}

struct ReaderView: View {
    @State var model: ReaderModel
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var panel: ReaderPanel?
    @State private var query = ""
    @AppStorage("readerFontSize") private var fontSize = 110.0
    @AppStorage("readerScroll") private var scroll = false
    @AppStorage("readerTheme") private var theme = "cream"
    @AppStorage("speechVoice") private var speechVoice = ""
    private enum ReaderPanel: String, Identifiable { case contents, search, annotations, appearance; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            Group {
                if let navigator = model.navigator { NativeReader(navigator: navigator).accessibilityIdentifier("reader.publication") }
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
                        if player.bookID == model.bookID, player.isPlaying { player.pause() }
                        else if let pub = model.publication, let book = model.book {
                            model.connectPlayback(player)
                            player.speak(publication: pub, book: book, from: model.navigator?.currentLocation)
                        }
                    } label: { Label(player.isPlaying && player.bookID == model.bookID ? "Pause" : "Read aloud", systemImage: player.isPlaying && player.bookID == model.bookID ? "pause.fill" : "headphones") }
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
            .alert("Reader", isPresented: Binding(get: { model.error != nil && !model.loading && model.navigator != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }.tint(Obsidian.accent)
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
                        ForEach(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: model.book?.language.prefix(2) ?? "en") }, id: \.identifier) { voice in Text(voice.name).tag(voice.identifier) }
                    }
                    Text("Install additional voices in iOS Settings → Accessibility → Spoken Content.").font(.caption).foregroundStyle(.secondary)
                }
            }.onChange(of: fontSize) { model.applyPreferences() }.onChange(of: theme) { model.applyPreferences() }.onChange(of: scroll) { model.applyPreferences() }
        }
    }
    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
}
