import XCTest
import ReadiumShared
import ReadiumZIPFoundation
@testable import BookPocketOpen

final class LibraryTests: XCTestCase {
    func testUnicodeScalarOffsetsAreNotUTF16Offsets() throws {
        let text = "A compass 🧭 pointed north; café bells sounded beyond the window."
        let range = try XCTUnwrap(SourceIdentity.scalarRange(10, 11, in: text))
        XCTAssertEqual(String(text[range]), "🧭")
        XCTAssertEqual(NSRange(range, in: text).length, 2)
        XCTAssertNil(SourceIdentity.scalarRange(-1, 2, in: text))
        XCTAssertNil(SourceIdentity.scalarRange(3, 999, in: text))
    }
    func testDatabaseSurvivesReopenAndReplacesAtomically() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.sqlite")
        do { let db = try LibraryDatabase(url: url); try db.write("test", value: ["original"]); try db.write("test", value: ["replacement", "🧭"]) }
        let reopened = try LibraryDatabase(url: url)
        XCTAssertEqual(try reopened.read("test", as: [String].self), ["replacement", "🧭"])
    }
    @MainActor func testTextImportPreservesOriginalAndDeduplicates() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("A small book.txt")
        let data = Data("A small book\n\nA compass 🧭 points north.\n\nRead & preserve <every> word.".utf8)
        try data.write(to: source)
        let library = LibraryStore(root: folder.appendingPathComponent("Library"))
        let book = try await library.importBook(source)
        let duplicate = try await library.importBook(source)
        XCTAssertEqual(book.id, duplicate.id)
        XCTAssertEqual(library.books.count, 1)
        XCTAssertEqual(try Data(contentsOf: library.file(book, original: true)), data)
        let publication = try await library.publications.open(library.file(book))
        XCTAssertFalse(publication.readingOrder.isEmpty)
        let text = await publication.content()?.text()
        XCTAssertTrue(text?.contains("Read & preserve <every> word.") == true)
        publication.close()
        XCTAssertEqual(LibraryStore(root: folder.appendingPathComponent("Library")).books.first?.id, book.id)
    }
    @MainActor func testImportRejectsTraversalBeforeOpeningPublication() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("test.txt")
        try Data("not a publication".utf8).write(to: source)
        let url = folder.appendingPathComponent("unsafe.epub")
        let archive = try await Archive(url: url, accessMode: .create)
        try await archive.addEntry(with: "../outside.txt", fileURL: source)
        do { try await PublicationService.validateArchive(url); XCTFail("Archive traversal must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unsafe")) }
    }
}
