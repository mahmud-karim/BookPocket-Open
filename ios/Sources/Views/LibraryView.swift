import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var showImporter = false
    @State private var query = ""
    @State private var selected: LocalBook?
    @State private var deleting: LocalBook?
    @AppStorage("appTheme") private var appTheme = "dark"
    @ScaledMetric(relativeTo: .largeTitle) private var welcomeSize = 38.0
    private var filtered: [LocalBook] { library.books.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }.sorted { $0.lastOpenedAt > $1.lastOpenedAt } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if library.books.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Image(systemName: "books.vertical").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(Obsidian.accent)
                            Text("A world,\nwithin reach.").font(.system(size: welcomeSize, weight: .regular, design: .serif))
                            Text("Bring your books. Read at your own pace, or let a voice carry the story.").font(.body).foregroundStyle(.secondary)
                            Button("Import a book", systemImage: "plus") { showImporter = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("library.import.empty")
                            Text("EPUB & plain text · Stored on your device").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(28).background(Obsidian.surface, in: .rect(cornerRadius: 22)).padding(.top, 12)
                    } else {
                        Text("YOUR COLLECTION").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 22)], alignment: .leading, spacing: 28) {
                            ForEach(filtered) { book in
                                Button { selected = book } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        BookCover(book: book, url: library.cover(book))
                                        Text(book.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                        Text(book.author.isEmpty ? "Imported book" : book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if book.progress > 0 { ProgressView(value: book.progress).tint(Obsidian.accent).accessibilityLabel("Reading progress") }
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("library.book.\(book.title)")
                                .contextMenu {
                                    ShareLink(item: library.file(book, original: true)) { Label("Share original", systemImage: "square.and.arrow.up") }
                                    Button("Remove from library", systemImage: "trash", role: .destructive) { deleting = book }
                                }
                            }
                        }
                    }
                }.padding(24)
            }.background(Obsidian.background)
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Books and authors")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu { Picker("Appearance", selection: $appTheme) { Text("Obsidian").tag("dark"); Text("Light").tag("light"); Text("System").tag("system") } } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                    Button("Import book", systemImage: "plus") { showImporter = true }.accessibilityIdentifier("library.import")
                }
            }
            .overlay { if library.importing { ProgressView("Importing book…").padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16)) } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data, .plainText], allowsMultipleSelection: true) { result in
                Task { do { for url in try result.get() { try await library.importBook(url) } } catch { library.error = error.localizedDescription } }
            }
            .fullScreenCover(item: $selected) { book in ReaderView(model: ReaderModel(bookID: book.id, library: library)) }
            .confirmationDialog("Remove this book and its reading history?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Remove book", role: .destructive) { if let deleting { do { try library.remove(deleting.id) } catch { library.error = error.localizedDescription } }; deleting = nil }
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--import-fixture"), let url = Bundle.main.url(forResource: "lantern", withExtension: "epub"), library.books.isEmpty {
                    do { try await library.importBook(url) } catch { library.error = error.localizedDescription }
                }
            }
        }
    }
}
