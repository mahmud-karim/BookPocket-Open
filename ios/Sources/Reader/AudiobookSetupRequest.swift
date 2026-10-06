import Foundation

/// Replaceable setup navigation boundary. The captured source snapshot preserves
/// exact book, chapter and page bounds across sheet presentation and reader reflow.
struct AudiobookSetupRequest: Identifiable {
    let id = UUID()
    let bookID: String
    let chapterTitle: String
    let scope: NarrationScope
    let mode: ReaderVoiceMode
    let snapshot: ReaderScopeSnapshot
}
