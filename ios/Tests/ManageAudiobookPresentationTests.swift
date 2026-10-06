import XCTest
@testable import BookPocketOpen

final class ManageAudiobookPresentationTests: XCTestCase {
    private var book: RemoteBook {
        .init(id: "original", title: "The Lantern", author: "Test", language: "en", sourceSha256: "abc", chapters: [
            .init(id: "one", title: "Chapter one", href: "one.xhtml", segments: [.init(id: "a", text: "Mira 🧭 says hello.", kind: "paragraph", locator: .object([:]))]),
            .init(id: "two", title: "Chapter two", href: "two.xhtml", segments: [.init(id: "b", text: "A second chapter.", kind: "paragraph", locator: .object([:]))])
        ])
    }
    private var voices: [RemoteVoice] { [.init(id: "narrator-voice", name: "Kyon", engine: "omnivoice", kind: "clone", language: "en")] }
    private var engines: [RemoteEngine] { [.init(id: "omnivoice", name: "OmniVoice", available: true, supportsCloning: true, languages: ["en"], license: "test")] }
    private var cast: BookCast { .init(characters: [.init(id: "narrator", name: "Narrator", aliases: [], voiceId: "narrator-voice"), .init(id: "mira", name: "Mira", aliases: [], voiceId: nil)], assignments: []) }
    private func job(_ status: String, completed: Int, stage: String? = nil) -> AnalysisJob {
        .init(id: "accepted", bookId: book.id, status: status, completedSegments: completed, totalSegments: 4, chapterIds: ["one"], stage: stage)
    }
    func testCanonicalChapterUsesOriginalUnicodeScalarBoundsAndNeverOtherChapter() throws {
        let source = try ManageAudiobookSource.chapter(book: book, chapterID: "one", localSHA256: "ABC")
        XCTAssertEqual(source.ranges, [.init(segmentId: "a", startOffset: 0, endOffset: book.chapters[0].segments[0].text.unicodeScalars.count)])
        XCTAssertEqual(source.text, book.chapters[0].segments[0].text)
        XCTAssertFalse(source.ranges.contains { $0.segmentId == "b" })
    }
    func testChangedSourceUnknownChapterAndDuplicateIDsAreRejected() {
        XCTAssertThrowsError(try ManageAudiobookSource.chapter(book: book, chapterID: "one", localSHA256: "other"))
        XCTAssertThrowsError(try ManageAudiobookSource.chapter(book: book, chapterID: "missing", localSHA256: "abc"))
        var duplicated = book; duplicated.chapters[1].segments[0].id = "a"
        XCTAssertThrowsError(try ManageAudiobookSource.chapter(book: duplicated, chapterID: "one", localSHA256: "abc"))
        duplicated = book; duplicated.chapters.append(book.chapters[0])
        XCTAssertThrowsError(try ManageAudiobookSource.chapter(book: duplicated, chapterID: "one", localSHA256: "abc"))
    }
    func testChapterCountsIncludeSuggestedMissingCharacterWithoutLeakingOtherChapter() {
        let issue = CastReviewIssue(id: "review", chapterId: "one", segmentId: "a", startOffset: 0, endOffset: 4, sourceText: "Mira", reason: "unreviewed_assignment", message: "Review", status: "pending", suggestedCharacterId: "mira")
        let review = CastReviewInventory(bookId: book.id, sourceSha256: "abc", revision: 0, issues: [issue])
        let statuses = [ChapterAnalysisStatus(chapterId: "one", status: "completed"), .init(chapterId: "two", status: "completed")]
        let first = ManageAudiobookSummary(chapter: book.chapters[0], cast: cast, voices: voices, engines: engines, review: review, statuses: statuses)
        XCTAssertEqual(first.missingVoiceCount, 1); XCTAssertEqual(first.pendingReviewCount, 1); XCTAssertFalse(first.needsAnalysis)
        let second = ManageAudiobookSummary(chapter: book.chapters[1], cast: cast, voices: voices, engines: engines, review: review, statuses: statuses)
        XCTAssertEqual(second.missingVoiceCount, 0); XCTAssertEqual(second.pendingReviewCount, 0); XCTAssertFalse(second.needsAnalysis)
    }
    func testMissingNarratorAndOfflineVoiceAreRealBlockers() {
        let review = CastReviewInventory(bookId: book.id, sourceSha256: "abc", revision: 0, issues: [])
        let absent = ManageAudiobookSummary(chapter: book.chapters[0], cast: .init(), voices: voices, engines: engines, review: review, statuses: [])
        XCTAssertEqual(absent.missingVoiceCount, 1); XCTAssertTrue(absent.needsAnalysis)
        var unavailable = engines; unavailable[0].available = false
        let offline = ManageAudiobookSummary(chapter: book.chapters[0], cast: cast, voices: voices, engines: unavailable, review: review, statuses: [])
        XCTAssertEqual(offline.missingVoiceCount, 1)
    }
    func testProgressReflectsWorkAndDoesNotClaimSavingIsFinished() {
        let half = ManageAnalysisProgress(job: job("running", completed: 2, stage: "analyzing"), mergingResults: false)
        XCTAssertEqual(half.fraction, 0.5); XCTAssertFalse(half.finished); XCTAssertEqual(half.step, 1)
        let saving = ManageAnalysisProgress(job: job("running", completed: 4, stage: "saving"), mergingResults: false)
        XCTAssertEqual(saving.fraction, 1); XCTAssertFalse(saving.finished); XCTAssertEqual(saving.stage, "Saving cast suggestions")
        let fetching = ManageAnalysisProgress(job: job("completed", completed: 4, stage: "completed"), mergingResults: true)
        XCTAssertFalse(fetching.finished); XCTAssertEqual(fetching.stage, "Saving cast suggestions")
        let complete = ManageAnalysisProgress(job: job("completed", completed: 4, stage: "completed"), mergingResults: false)
        XCTAssertTrue(complete.finished); XCTAssertEqual(complete.stage, "Analysis complete")
    }
    func testLegacyUnknownTotalsUseIndeterminateProgress() {
        var legacy = job("queued", completed: 0); legacy.totalSegments = 0
        let progress = ManageAnalysisProgress(job: legacy, mergingResults: false)
        XCTAssertNil(progress.fraction); XCTAssertFalse(progress.finished)
        let invalid = ManageAnalysisProgress(job: job("failed", completed: 20), mergingResults: false)
        XCTAssertEqual(invalid.fraction, 1); XCTAssertTrue(invalid.failed); XCTAssertFalse(invalid.finished)
    }
    @MainActor func testServerIDRecoveryOnlyPollsAndPreservesHumanVoiceEdits() async {
        var server = cast
        let draft = CastDraft()
        var submitted = 0, saved = 0, polled = 0
        let service = CastService(fetch: { server }, save: { _ in saved += 1 }, analyze: { _ in submitted += 1; return self.job("completed", completed: 4) }, poll: { id in
            XCTAssertEqual(id, "accepted"); polled += 1
            server.characters.append(.init(id: "new", name: "New suggestion", aliases: [], voiceId: nil))
            return self.job("completed", completed: 4)
        }, requireReliableAnalysis: {}, wait: {})
        await draft.load(book: book, service: service)
        draft.value.characters[0].voiceId = "human-new-voice"
        await draft.resumeExisting(book: book, job: job("running", completed: 2), service: service)
        XCTAssertEqual(submitted, 0); XCTAssertEqual(saved, 0); XCTAssertEqual(polled, 1)
        XCTAssertEqual(draft.value.characters[0].voiceId, "human-new-voice")
        XCTAssertTrue(draft.value.characters.contains { $0.id == "new" }); XCTAssertTrue(draft.dirty)
    }
    @MainActor func testRecoveryRejectsDifferentBookWithoutPolling() async {
        let draft = CastDraft(); var polled = false
        let service = CastService(fetch: { self.cast }, save: { _ in }, analyze: { _ in self.job("completed", completed: 4) }, poll: { _ in polled = true; return self.job("completed", completed: 4) }, requireReliableAnalysis: {})
        var wrong = job("running", completed: 2); wrong.bookId = "other"
        await draft.resumeExisting(book: book, job: wrong, service: service)
        XCTAssertFalse(polled); XCTAssertNil(draft.analysis)
    }
}
