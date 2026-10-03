import Foundation
import Observation
import ReadiumShared
import ReadiumNavigator
import UIKit

@MainActor @Observable final class ReaderModel: NSObject, EPUBNavigatorDelegate {
    var navigator: EPUBNavigatorViewController?
    var publication: Publication?
    var location: Locator?
    var error: String?
    var loading = true
    var pageReady = false
    var searchResults: [Locator] = []
    var searching = false
    var capturingScope = false
    var sourceDocuments: [String: SourceDocument] = [:]
    let bookID: String
    private let library: LibraryStore
    init(bookID: String, library: LibraryStore) { self.bookID = bookID; self.library = library }
    var book: LocalBook? { library.book(bookID) }
    var chapters: [Link] { publication?.manifest.tableOfContents ?? [] }
    func load() async {
        guard navigator == nil, let book else { return }
        do {
            let publication = try await library.publications.open(library.file(book))
            self.publication = publication
            let actions = EditingAction.defaultActions + [EditingAction(title: "Highlight", action: #selector(ReaderContainer.highlightSelection(_:)))]
            let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: book.locator, config: .init(preferences: preferences(), editingActions: actions))
            navigator.delegate = self
            self.navigator = navigator
            location = book.locator
            refreshHighlights()
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func preferences(defaults: UserDefaults = .standard) -> EPUBPreferences {
        var prefs = EPUBPreferences()
        // The UI stores a percentage; Readium 3 expects a scale factor (1.0 = 100%).
        let percentage = defaults.double(forKey: "readerFontSize")
        prefs.fontSize = min(200, max(75, percentage == 0 ? 110 : percentage)) / 100
        prefs.publisherStyles = false
        prefs.scroll = defaults.bool(forKey: "readerScroll")
        prefs.theme = defaults.string(forKey: "readerTheme") == "white" ? .light : defaults.string(forKey: "readerTheme") == "dark" ? .dark : .sepia
        prefs.fontFamily = .serif
        prefs.lineHeight = 1.6
        return prefs
    }
    func applyPreferences() { navigator?.submitPreferences(preferences()) }
    func addAnnotation(highlight: Bool) {
        guard var book, let locator = highlight ? navigator?.currentSelection?.locator : navigator?.currentLocation else {
            error = highlight ? "Select a passage in the book first, then tap Highlight." : "Wait for the book to finish opening."
            return
        }
        guard let json = try? locator.jsonString() else { return }
        book.annotations.append(BookAnnotation(kind: highlight ? "highlight" : "bookmark", text: locator.text.highlight ?? locator.title ?? "Reading position", locatorJSON: json))
        library.update(book)
        navigator?.clearSelection()
        refreshHighlights()
    }
    func removeAnnotation(_ annotation: BookAnnotation) {
        guard var book else { return }
        book.annotations.removeAll { $0.id == annotation.id }
        library.update(book)
        refreshHighlights()
    }
    func refreshHighlights() {
        let decorations = (book?.annotations ?? []).filter { $0.kind == "highlight" }.compactMap { item -> Decoration? in
            guard let locator = item.locator else { return nil }
            return Decoration(id: item.id, locator: locator, style: .highlight(tint: UIColor(red: 0.86, green: 0.77, blue: 0.61, alpha: 0.5)))
        }
        navigator?.apply(decorations: decorations, in: "annotations")
    }
    func follow(_ locator: Locator) {
        navigator?.apply(decorations: [Decoration(id: "spoken", locator: locator, style: .highlight(tint: .systemYellow, isActive: true))], in: "speech")
        Task { await navigator?.go(to: locator) }
    }
    func connectPlayback(_ player: PlaybackController) {
        let library = library
        let id = bookID
        var saved = Date.distantPast
        player.onLocator = { [weak self] locator in
            self?.follow(locator)
            if Date().timeIntervalSince(saved) >= 3 { library.saveLocation(id, locator: locator); saved = Date() }
        }
    }
    func search(_ query: String) async {
        guard let publication, !query.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = []; return }
        searching = true
        defer { searching = false }
        do {
            let iterator = try await publication.search(query: query).get()
            defer { iterator.close() }
            var results: [Locator] = []
            while let page = try await iterator.next().get(), !Task.isCancelled {
                results.append(contentsOf: page.locators)
                if results.count >= 500 { break }
            }
            if !Task.isCancelled { searchResults = results }
        } catch { self.error = error.localizedDescription }
    }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) { location = locator; library.saveLocation(bookID, locator: locator) }
    func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
        // Opening readiness is sticky; transient page turns must not rebuild an open toolbar menu.
        if viewport != nil && !pageReady { pageReady = true }
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { self.error = String(describing: error) }
}
