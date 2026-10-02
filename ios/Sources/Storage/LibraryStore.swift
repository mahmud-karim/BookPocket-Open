import Foundation
import Observation
import ReadiumShared

@MainActor @Observable final class LibraryStore {
    private(set) var books: [LocalBook] = []
    var error: String?
    var importing = false
    let root: URL
    let publications = PublicationService()
    private var database: LibraryDatabase?
    init(root: URL? = nil) {
        self.root = root ?? URL.documentsDirectory.appendingPathComponent("Library", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            database = try LibraryDatabase(url: self.root.appendingPathComponent("library.sqlite"))
            books = try database?.read("books", as: [LocalBook].self) ?? []
        } catch { self.error = error.localizedDescription }
    }
    func file(_ book: LocalBook, original: Bool = false) -> URL { root.appendingPathComponent(book.id).appendingPathComponent(original ? book.sourceFile : book.readingFile) }
    func cover(_ book: LocalBook) -> URL? { book.coverFile.map { root.appendingPathComponent(book.id).appendingPathComponent($0) } }
    func book(_ id: String) -> LocalBook? { books.first { $0.id == id } }
    func persist() throws {
        guard let database else { throw BookError.message("Library storage is unavailable. Your original books have not been changed.") }
        try database.write("books", value: books)
    }
    func update(_ book: LocalBook) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        let previous = books[i]
        books[i] = book
        do { try persist() } catch { books[i] = previous; self.error = error.localizedDescription }
    }
    func saveLocation(_ id: String, locator: Locator) {
        guard var book = book(id), let json = try? locator.jsonString() else { return }
        book.locatorJSON = json
        book.progress = locator.locations.totalProgression ?? book.progress
        book.lastOpenedAt = Date()
        update(book)
    }
    func remove(_ id: String) throws {
        let previous = books
        books.removeAll { $0.id == id }
        do { try persist() } catch { books = previous; throw error }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }
    @discardableResult func importBook(_ url: URL) async throws -> LocalBook {
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard ["epub", "txt"].contains(url.pathExtension.lowercased()) else { throw BookError.message("Choose a DRM-free EPUB or plain text file.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 250 * 1024 * 1024 else { throw BookError.message("Books must be between 1 byte and 250 MB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SourceIdentity.hash(data)
        if let duplicate = books.first(where: { $0.sourceSHA256 == hash }) { return duplicate }
        let id = UUID().uuidString.lowercased()
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let original = "original." + url.pathExtension.lowercased()
        try data.write(to: folder.appendingPathComponent(original), options: .atomic)
        let reading = url.pathExtension.lowercased() == "txt" ? "reading.epub" : original
        if reading != original { try await PublicationService.makeEPUB(from: folder.appendingPathComponent(original), to: folder.appendingPathComponent(reading), title: url.deletingPathExtension().lastPathComponent) }
        try await PublicationService.validateArchive(folder.appendingPathComponent(reading))
        let publication = try await publications.open(folder.appendingPathComponent(reading))
        defer { publication.close() }
        var book = LocalBook(id: id, title: publication.metadata.title ?? url.deletingPathExtension().lastPathComponent, author: publication.metadata.authors.map(\.name).joined(separator: ", "), language: publication.metadata.languages.first ?? "en", sourceFile: original, readingFile: reading, sourceSHA256: hash)
        if let image = try? await publication.cover().get(), let jpg = image.jpegData(compressionQuality: 0.85) {
            try jpg.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
            book.coverFile = "cover.jpg"
        }
        books.insert(book, at: 0)
        do { try persist() } catch { books.removeAll { $0.id == id }; throw error }
        succeeded = true
        return book
    }
}
