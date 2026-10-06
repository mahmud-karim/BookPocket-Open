import XCTest
import UIKit

final class ReaderUITests: XCTestCase {
    func testFullCastUnclearTextReviewSavesExactSpeakerAndVoiceAndUnblocksGeneration() {
        executionTimeAllowance = 300
        let app = castReviewApp()
        app.launch(); openCastReviewReader(app)
        requestCastReview(app)
        chooseNewReviewSpeaker(app)
        narrationToolsScreenshot(app, "Obsidian original unclear passage with explicit speaker and voice")
        let save = app.buttons["cast.review.save"]
        scrollReviewTo(save, app: app); XCTAssertTrue(save.isEnabled && save.isHittable); save.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)], timeout: 20), .completed)
        let close = app.buttons["Save & close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(app.buttons["reader.player.generate"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["reader.player.review"].exists, "An explicit saved review removes this scope's blocker")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled, "Review does not fabricate generated audio")
        app.buttons["reader.player.generate"].tap()
        XCTAssertTrue(app.buttons["reader.generate.chapter"].waitForExistence(timeout: 10)); app.buttons["reader.generate.chapter"].tap()
        let queued = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Queued")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 20), "Only the authenticated resolved exact-source plan can queue generation")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        narrationToolsScreenshot(app, "Obsidian full cast queued only after original text review")
        app.terminate(); app.launch(); openCastReviewReader(app)
        app.buttons["reader.player.generate"].tap()
        XCTAssertTrue(app.buttons["reader.generate.chapter"].waitForExistence(timeout: 10)); app.buttons["reader.generate.chapter"].tap()
        XCTAssertTrue(queued.waitForExistence(timeout: 20), "A restarted app prepares the persisted reviewed cast through the authenticated transport")
        XCTAssertFalse(app.buttons["reader.player.review"].exists, "The original review survives a real app restart")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        app.navigationBars["Read aloud"].buttons["Done"].tap(); app.buttons["reader.close"].tap()
        app.tabBars.buttons["Studio"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "studio.job.cast-review-generated").firstMatch.waitForExistence(timeout: 15), "The accepted generation request remains saved without simulated audio")
    }

    func testFullCastUnclearTextReviewFailureKeepsChoicesAndDoesNotGenerate() {
        executionTimeAllowance = 300
        let app = castReviewApp(); app.launchArguments.append("--cast-review-conflict")
        app.launch(); openCastReviewReader(app); requestCastReview(app); chooseNewReviewSpeaker(app)
        let save = app.buttons["cast.review.save"]
        scrollReviewTo(save, app: app); XCTAssertTrue(save.isEnabled && save.isHittable); save.tap()
        let error = app.staticTexts["cast.review.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15)); XCTAssertTrue(error.label.contains("changed on your PC"))
        let speaker = app.descendants(matching: .any).matching(identifier: "cast.review.speaker").firstMatch
        let voice = app.descendants(matching: .any).matching(identifier: "cast.review.voice").firstMatch
        scrollReviewTo(speaker, app: app, seekEarlier: true)
        XCTAssertTrue((speaker.label + " " + String(describing: speaker.value)).contains("Mira"))
        scrollReviewTo(voice, app: app)
        XCTAssertTrue((voice.label + " " + String(describing: voice.value)).contains("Mira review voice"))
        scrollReviewTo(error, app: app)
        narrationToolsScreenshot(app, "Obsidian conflicting review save preserves speaker and voice")
        app.buttons["cast.review.cancel"].tap()
        let close = app.buttons["Save & close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(app.buttons["reader.player.review"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        app.terminate(); app.launch(); openCastReviewReader(app)
        app.buttons["reader.player.generate"].tap()
        XCTAssertTrue(app.buttons["reader.generate.chapter"].waitForExistence(timeout: 10)); app.buttons["reader.generate.chapter"].tap()
        XCTAssertTrue(app.buttons["reader.player.review"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        narrationToolsScreenshot(app, "Obsidian unresolved review remains blocked after restart")
        app.navigationBars["Read aloud"].buttons["Done"].tap(); app.buttons["reader.close"].tap()
        app.tabBars.buttons["Studio"].tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "studio.job.cast-review-generated").firstMatch.exists, "A failed review cannot silently generate or replace a voice")
    }

    private func castReviewApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--cast-review-fixture", "--review-persistence-id=" + UUID().uuidString]
        return app
    }
    private func openCastReviewReader(_ app: XCUIApplication) {
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 30)); app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 45)); book.tap(); XCTAssertTrue(waitForReaderContents(app))
        let original = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "🧭 Café bells rang.")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15)); XCTAssertTrue(original.label.contains("“Keep the lantern steady."))
        app.buttons["reader.speak"].tap(); chooseReaderNarrator(app, "cast")
    }
    private func requestCastReview(_ app: XCUIApplication) {
        app.buttons["reader.player.generate"].tap()
        XCTAssertTrue(app.buttons["reader.generate.chapter"].waitForExistence(timeout: 10)); app.buttons["reader.generate.chapter"].tap()
        let review = app.buttons["reader.player.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 20)); XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        assertMinimumHitArea(review); review.tap()
        let exact = app.staticTexts["cast.review.exact"]
        XCTAssertTrue(exact.waitForExistence(timeout: 20))
        XCTAssertEqual(exact.label, "🧭 Café bells rang. Mira said, “Keep the lantern steady.")
        narrationToolsScreenshot(app, "Obsidian original Unicode passage before assigning its speaker")
        let save = app.buttons["cast.review.save"]
        scrollReviewTo(save, app: app, requireHittable: false)
        XCTAssertTrue(save.waitForExistence(timeout: 10), "The initial disabled Save row must be materialized on a compact Form")
        XCTAssertFalse(save.isEnabled, "An unclear passage requires an explicit speaker and voice")
    }
    private func chooseNewReviewSpeaker(_ app: XCUIApplication) {
        let name = app.textFields["cast.review.newCharacter"]
        scrollReviewTo(name, app: app, seekEarlier: true); XCTAssertTrue(name.isHittable); name.tap(); name.typeText("Mira")
        let add = app.buttons["cast.review.addCharacter"]
        XCTAssertTrue(add.isEnabled); add.tap()
        let voice = app.descendants(matching: .any).matching(identifier: "cast.review.voice").firstMatch
        scrollReviewTo(voice, app: app); XCTAssertTrue(voice.isHittable); voice.tap()
        let choice = app.buttons["Mira review voice"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10)); choice.tap()
        let create = app.buttons["cast.review.createVoice"], save = app.buttons["cast.review.save"]
        scrollReviewTo(create, app: app); XCTAssertTrue(create.waitForExistence(timeout: 10)); XCTAssertTrue(create.isEnabled)
        scrollReviewTo(save, app: app); XCTAssertTrue(save.waitForExistence(timeout: 10)); XCTAssertTrue(save.isEnabled)
        let speaker = app.descendants(matching: .any).matching(identifier: "cast.review.speaker").firstMatch
        scrollReviewTo(speaker, app: app, seekEarlier: true)
    }
    private func scrollReviewTo(_ element: XCUIElement, app: XCUIApplication, seekEarlier: Bool = false, requireHittable: Bool = true) {
        for _ in 0..<12 {
            // The reader beneath this sheet contains a 44-point horizontal
            // scroll view. Select the visible vertical Form instead of that
            // first unrelated ScrollView, and keep drags above the keyboard.
            let containers = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            let form = containers.filter { $0.exists && $0.isHittable && $0.frame.height >= 200 && $0.frame.width >= app.frame.width * 0.7 }
                .max { $0.frame.height < $1.frame.height }
            let surface = form ?? app
            let navigation = app.navigationBars["Review dialogue"]
            let top = max(surface.frame.minY, navigation.exists ? navigation.frame.maxY + 8 : app.frame.minY + 100)
            let keyboard = app.keyboards.firstMatch
            let bottom = min(surface.frame.maxY, keyboard.exists ? keyboard.frame.minY - 8 : app.frame.maxY - 30)
            guard bottom - top >= 100 else { return }
            let materialized = element.exists && !element.frame.isEmpty
            if materialized && element.frame.minY >= top && element.frame.maxY <= bottom && (!requireHittable || element.isHittable) { return }
            // SwiftUI's compact Form virtualizes offscreen rows. Their absence
            // carries no direction, so callers explicitly seek earlier rows.
            let down = materialized ? element.frame.minY < top : seekEarlier
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.5, dy: top + (bottom - top) * (down ? 0.35 : 0.75)))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.5, dy: top + (bottom - top) * (down ? 0.75 : 0.35)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    func testMiniPlayerDismissalAndListeningSelectionSurviveRestart() {
        executionTimeAllowance = 300
        let app = narrationToolsApp()
        app.launchArguments.append("--transport-persistence-id=" + UUID().uuidString)
        app.launch(); openContinuousPage(app)
        let readerPlay = app.buttons["reader.player.toggle"]
        readerPlay.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: readerPlay)], timeout: 10), .completed)
        readerPlay.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Paused"), object: readerPlay)], timeout: 10), .completed)
        let baseline = audioSeconds(app.staticTexts["reader.player.elapsed"])
        app.buttons["reader.player.forward"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.elapsed"]), baseline + 15, accuracy: 1)
        app.navigationBars["Read aloud"].buttons["Done"].tap(); app.buttons["reader.close"].tap()
        let close = app.buttons["player.mini.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); assertMinimumHitArea(close)
        narrationToolsScreenshot(app, "Obsidian mini player with accessible close control")
        close.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)], timeout: 5), .completed)
        app.tabBars.buttons["Listen"].tap()
        let play = app.buttons["player.full.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 124, "Restore the selected page, not the available 184-second chapter")
        XCTAssertEqual(app.staticTexts["listen.scope"].label, "Page recording")
        app.buttons["listen.speed"].tap(); XCTAssertTrue(app.buttons["1.5×"].waitForExistence(timeout: 5)); app.buttons["1.5×"].tap()
        let position = audioSeconds(app.staticTexts["listen.elapsed"])
        for name in ["Library", "Studio", "Connection", "Listen"] {
            XCTAssertTrue(app.tabBars.buttons[name].isHittable); app.tabBars.buttons[name].tap(); XCTAssertFalse(close.exists)
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30)); app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 15)); XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.elapsed"]), position, accuracy: 1)
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 124)
        XCTAssertEqual(app.staticTexts["listen.scope"].label, "Page recording")
        XCTAssertEqual(app.buttons["listen.speed"].value as? String, "1.5×"); XCTAssertFalse(close.exists)
        narrationToolsScreenshot(app, "Obsidian exact offline page restored paused after app restart")
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 10), .completed)
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Explicit playback reopens the dismissed mini player")
        close.tap(); app.tabBars.buttons["Listen"].tap(); XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 124)
    }

    func testStudioFailedJobDeletionRequiresConfirmationAndKeepsOfflineRow() {
        executionTimeAllowance = 300
        let app = narrationToolsApp()
        app.launchArguments += ["--studio-failed-jobs-fixture", "--transport-persistence-id=" + UUID().uuidString]
        app.launch(); XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30)); app.tabBars.buttons["Studio"].tap()
        let delete = app.buttons["studio.job.delete.studio-failed-fixture"]
        scrollStudioJobTo(delete, app: app); XCTAssertTrue(delete.waitForExistence(timeout: 10)); XCTAssertTrue(delete.isHittable); delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let cancel = alert.buttons.matching(identifier: "studio.job.delete.cancel").firstMatch
        let confirm = alert.buttons.matching(identifier: "studio.job.delete.confirm").firstMatch
        XCTAssertTrue(cancel.isHittable); XCTAssertEqual(cancel.label, "Cancel"); XCTAssertEqual(confirm.label, "Delete job")
        narrationToolsScreenshot(app, "Obsidian failed production job deletion confirmation")
        cancel.tap(); XCTAssertTrue(delete.exists, "Cancel keeps the failed queue entry")
        delete.tap(); XCTAssertTrue(alert.waitForExistence(timeout: 5)); confirm.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Pair your PC")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(delete.exists, "Offline deletion keeps its queue entry")
        narrationToolsScreenshot(app, "Obsidian offline failed job deletion preserves queue")
        app.terminate(); app.launch(); XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30)); app.tabBars.buttons["Studio"].tap()
        scrollStudioJobTo(delete, app: app); XCTAssertTrue(delete.waitForExistence(timeout: 10))
        let cancelled = app.buttons["studio.job.delete.studio-cancelled-fixture"]
        scrollStudioJobTo(cancelled, app: app); XCTAssertTrue(cancelled.exists, "The cancelled job remains separately manageable")
        app.tabBars.buttons["Listen"].tap(); app.buttons["listen.downloads"].tap()
        XCTAssertTrue(app.buttons["listen.download.reader-continuous-page"].waitForExistence(timeout: 10), "Unrelated completed recordings survive failed deletion")
    }

    func testReaderWordHighlightingUsesOriginalWordsAcrossContinuousRecording() {
        executionTimeAllowance = 300
        let app = narrationToolsApp(); app.launch(); openContinuousPage(app)
        let toggle = app.buttons["reader.player.toggle"], surface = app.otherElements["reader.player.surface"]
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: toggle)], timeout: 10), .completed)
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Paused"), object: toggle)], timeout: 10), .completed)
        // XCTest's normalized slider gesture may settle at 34 seconds on the
        // compact phone, outside Mira's [4, 34) interval. Use the precise skip
        // control here, then exercise the slider across the next word boundary.
        let pausedPosition = audioSeconds(app.staticTexts["reader.player.elapsed"])
        app.buttons["reader.player.forward"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Mira"), object: surface)], timeout: 10), .completed)
        let miraPosition = audioSeconds(app.staticTexts["reader.player.elapsed"])
        XCTAssertEqual(miraPosition, pausedPosition + 15, accuracy: 1)
        XCTAssertGreaterThan(miraPosition, 4); XCTAssertLessThan(miraPosition, 34, "The observed joined clock must lie inside Mira's actual fixture interval")
        XCTAssertEqual(toggle.value as? String, "Paused")
        narrationToolsScreenshot(app, "Obsidian original word highlighting after 15 second skip")
        app.sliders["reader.player.seek"].adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "opened"), object: surface)], timeout: 10), .completed)
        let position = audioSeconds(app.staticTexts["reader.player.elapsed"])
        XCTAssertGreaterThan(position, 34); XCTAssertLessThan(position, 64, "The observed joined clock must lie inside opened's actual fixture interval")
        XCTAssertEqual(toggle.value as? String, "Paused"); XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.duration"]), 124)
        narrationToolsScreenshot(app, "Obsidian individual original word in continuous page timeline")
        app.buttons["Done"].tap()
        let original = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15)); XCTAssertFalse(original.label.contains("Mee rah"))
        narrationToolsScreenshot(app, "Obsidian original reader word highlight after paused seek")
        app.buttons["reader.speak"].tap(); app.buttons["reader.player.details"].tap()
        XCTAssertEqual(app.staticTexts["reader.player.timing"].label, "Word highlighting")
        XCTAssertFalse(app.buttons["reader.alignment.enable"].exists)
    }
    func testReaderRecordingRemovalKeepsOtherTakes() {
        executionTimeAllowance = 300
        let app = narrationToolsApp(); app.launch(); openContinuousPage(app)
        app.buttons["reader.player.saved"].tap()
        let manage = app.buttons["reader.saved.manage.reader-continuous-page"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        app.buttons["reader.saved.delete.reader-continuous-page"].tap()
        let confirmation = app.alerts.firstMatch
        // SwiftUI's alert bridge exposes a button and its identically labelled
        // child on this OS. Select that specific action's first matching node.
        let cancel = confirmation.buttons.matching(identifier: "reader.recording.cancel").firstMatch
        let confirm = confirmation.buttons.matching(identifier: "reader.recording.confirm").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); XCTAssertTrue(cancel.isHittable)
        XCTAssertEqual(cancel.label, "Cancel"); XCTAssertEqual(confirm.label, "Delete generated take")
        narrationToolsScreenshot(app, "Obsidian confirmed whole take deletion")
        cancel.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirmation)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["reader.saved.reader-continuous-page"].label.contains("Ready offline"))
        manage.tap(); app.buttons["reader.saved.remove.reader-continuous-page"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); XCTAssertEqual(confirm.label, "Remove download"); confirm.tap()
        let page = app.buttons["reader.saved.reader-continuous-page"], chapter = app.buttons["reader.saved.reader-continuous-chapter"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "On PC"), object: page)], timeout: 10), .completed)
        XCTAssertTrue(chapter.label.contains("Ready offline"), "Another take retains shared audio files after phone-only removal")
        narrationToolsScreenshot(app, "Obsidian removed phone download with other take retained")
        manage.tap(); app.buttons["reader.saved.delete.reader-continuous-page"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); XCTAssertEqual(confirm.label, "Delete generated take"); confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Pair your PC")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(page.exists); XCTAssertTrue(chapter.label.contains("Ready offline"), "Offline PC deletion cannot remove other recordings")
    }
    func testReaderPronunciationCorrectionsPersistAndLeaveBookUnchanged() {
        executionTimeAllowance = 300
        let app = narrationToolsApp(); app.launch()
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30)); app.tabBars.buttons["Library"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch.tap()
        XCTAssertTrue(waitForReaderContents(app)); app.buttons["reader.options"].tap(); app.buttons["reader.pronunciation"].tap()
        let term = app.textFields["pronunciation.term"], replacement = app.textFields["pronunciation.replacement"]
        XCTAssertTrue(term.waitForExistence(timeout: 10)); term.tap(); term.typeText("Mira"); replacement.tap(); replacement.typeText("Mee rah")
        app.buttons["pronunciation.keyboard.done"].tap()
        narrationToolsScreenshot(app, "Obsidian pronunciation correction and labelled Apple preview")
        app.buttons["pronunciation.save"].tap()
        let edit = app.buttons["pronunciation.edit.Mira"]
        toolsScrollTo(edit, app: app); XCTAssertTrue(edit.exists)
        narrationToolsScreenshot(app, "Obsidian pronunciation saved offline for future audio")
        app.buttons["pronunciation.done"].tap()
        let original = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15)); XCTAssertFalse(original.label.contains("Mee rah"))
        app.buttons["reader.options"].tap(); app.buttons["reader.pronunciation"].tap()
        toolsScrollTo(edit, app: app); edit.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: term)], timeout: 5), .completed, "Editing a saved correction should bring its fields into view without a manual scroll")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Mira"), object: term)], timeout: 5), .completed)
        XCTAssertEqual(term.value as? String, "Mira"); XCTAssertEqual(replacement.value as? String, "Mee rah")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Selecting Edit should not open the keyboard")
        narrationToolsScreenshot(app, "Obsidian saved pronunciation edit fields brought into view")
        toolsScrollTo(edit, app: app)
        XCTAssertTrue(edit.exists, "Editing must not trigger the separate Remove correction action in this Form row")
        toolsScrollTo(app.buttons["pronunciation.regenerate"], app: app); app.buttons["pronunciation.regenerate"].tap()
        XCTAssertTrue(app.buttons["reader.generate.page"].waitForExistence(timeout: 20)); XCTAssertTrue(app.buttons["reader.generate.chapter"].exists)
        narrationToolsScreenshot(app, "Obsidian pronunciation regenerate exact page or chapter")
    }
    private func narrationToolsApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", "--reader-narration-tools-fixture", "-playbackRate", "0.5"]
        return app
    }
    private func toolsScrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }
    private func scrollStudioJobTo(_ element: XCUIElement, app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            // A compact phone can move the target above the navigation bar.
            // Use its current frame to reverse direction instead of overshooting.
            let moveDown = element.exists && element.frame.minY < top
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.42 : 0.72))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.72 : 0.42))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
    private func narrationToolsScreenshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testStartCompanionVerifiesReadinessAndFitsScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--connection-fixture", "--connection-startable"]
        app.launch()
        let unavailable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Unavailable"), object: app.staticTexts["connection.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 15), .completed)
        let start = app.buttons["connection.start"]
        assertMinimumHitArea(start)
        XCTAssertTrue(start.isEnabled && start.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0)
        for id in ["connection.toggle", "connection.edit", "connection.forget"] {
            let button = app.buttons[id]
            assertMinimumHitArea(button)
            XCTAssertTrue(button.isHittable)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.tabBars.firstMatch.frame.minY)
        }
        XCTAssertLessThanOrEqual(app.staticTexts["connection.retention"].frame.maxY, app.tabBars.firstMatch.frame.minY)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Obsidian Start companion — unavailable test host"; screen.lifetime = .keepAlways; add(screen)
        start.tap()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Connected"), object: app.staticTexts["connection.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 20), .completed)
        XCTAssertFalse(start.exists)
        for name in ["Library", "Listen", "Studio", "Connection"] { XCTAssertTrue(app.tabBars.buttons[name].isHittable) }
        XCTAssertEqual(app.buttons["connection.toggle"].label, "Disconnect")
    }
    func testStartCompanionFailureKeepsUnavailableAndPairing() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--connection-fixture", "--connection-startable", "--connection-start-fails"]
        app.launch()
        let start = app.buttons["connection.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        XCTAssertTrue(app.alerts["Connection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts["Connection"].staticTexts["Pocket Hub test receiver could not acknowledge the launch."].exists)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Obsidian Start companion — actionable test failure"; screen.lifetime = .keepAlways; add(screen)
        app.alerts["Connection"].buttons["OK"].tap()
        XCTAssertEqual(app.staticTexts["connection.status"].label, "Unavailable")
        XCTAssertTrue(start.isEnabled && start.isHittable)
        XCTAssertTrue(app.buttons["connection.edit"].isHittable)
        XCTAssertEqual(app.buttons["connection.toggle"].label, "Disconnect")
    }
    func testConnectionSettingsRemainReachableAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--connection-fixture", "--connection-unavailable", "--content-size-probe",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        let probe = app.descendants(matching: .any).matching(identifier: "test.content-size").firstMatch
        let expected = "UIKit=\(UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue); SwiftUI=accessibility5"
        let actual = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [actual], timeout: 30), .completed)
        let edit = app.buttons["connection.edit"]
        for _ in 0..<6 {
            if edit.exists && edit.isHittable && app.frame.contains(edit.frame) && edit.frame.maxY <= app.tabBars.firstMatch.frame.minY { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(edit.isHittable)
        assertMinimumHitArea(edit)
        XCTAssertTrue(app.tabBars.buttons["Connection"].isHittable)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Obsidian Connection largest text — reachable settings"; screen.lifetime = .keepAlways; add(screen)
        edit.tap()
        XCTAssertTrue(app.textFields["connection.address"].waitForExistence(timeout: 10))
    }

    func testConnectionTabShowsVerifiedStatusAndKeepsPairing() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--connection-fixture"]
        app.launch()
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Connected"), object: app.staticTexts["connection.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 15), .completed)
        for name in ["Library", "Listen", "Studio", "Connection"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.exists && tab.isHittable)
            XCTAssertTrue(app.frame.contains(tab.frame))
        }
        XCTAssertTrue(app.tabBars.buttons["Connection"].isSelected)
        for id in ["connection.toggle", "connection.edit", "connection.forget"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.exists && button.isHittable)
            XCTAssertTrue(app.frame.contains(button.frame))
            assertMinimumHitArea(button)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.tabBars.firstMatch.frame.minY)
        }
        let footer = app.staticTexts["connection.retention"]
        let position = footer.frame
        app.swipeUp()
        XCTAssertEqual(footer.frame, position, "Connection controls should fit without scrolling at standard text size")
        let connected = XCTAttachment(screenshot: app.screenshot())
        connected.name = "Obsidian Connection connected — isolated transport fixture"; connected.lifetime = .keepAlways; add(connected)
        app.buttons["connection.toggle"].tap()
        XCTAssertEqual(app.buttons["connection.toggle"].label, "Connect")
        XCTAssertTrue(app.staticTexts["connection.status"].label.contains("Disconnected"))
        XCTAssertTrue(app.buttons["connection.edit"].exists, "Disconnect must keep pairing settings")
        app.tabBars.buttons["Studio"].tap()
        XCTAssertTrue(app.buttons["studio.primary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["studio.primary"].label.contains("Create narration"), "Disconnect must not request a new pairing")
        app.tabBars.buttons["Connection"].tap()
        let disconnected = XCTAttachment(screenshot: app.screenshot())
        disconnected.name = "Obsidian Connection disconnected — pairing retained"; disconnected.lifetime = .keepAlways; add(disconnected)
        app.buttons["connection.toggle"].tap()
        let reconnected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Connected"), object: app.staticTexts["connection.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [reconnected], timeout: 15), .completed)
        XCTAssertEqual(app.buttons["connection.toggle"].label, "Disconnect")
        app.buttons["connection.forget"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["connection.edit"].exists, "Cancel must retain pairing")
    }

    func testConnectionOfflineForgetAndPairingEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--connection-fixture", "--connection-unavailable"]
        app.launch()
        let offline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Unavailable"), object: app.staticTexts["connection.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [offline], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["connection.help"].label.contains("Start companion"))
        XCTAssertTrue(app.buttons["connection.edit"].isHittable)
        let unavailable = XCTAttachment(screenshot: app.screenshot())
        unavailable.name = "Obsidian Connection unavailable — isolated transport fixture"; unavailable.lifetime = .keepAlways; add(unavailable)
        app.buttons["connection.forget"].tap(); app.buttons["Forget PC"].tap()
        XCTAssertTrue(app.buttons["connection.pair"].waitForExistence(timeout: 10))
        let unpaired = XCTAttachment(screenshot: app.screenshot())
        unpaired.name = "Obsidian Connection unpaired — original empty state"; unpaired.lifetime = .keepAlways; add(unpaired)
        app.buttons["connection.pair"].tap()
        XCTAssertTrue(app.navigationBars["Pair companion"].waitForExistence(timeout: 10))
        app.navigationBars["Pair companion"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["connection.pair"].exists)
    }

    func testCompanionAddressChangeVerifiesBeforeReplacingPairing() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--connection-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["connection.edit"].waitForExistence(timeout: 20))
        func openConnection() {
            app.buttons["connection.edit"].tap()
            XCTAssertTrue(app.textFields["connection.address"].waitForExistence(timeout: 10))
        }
        func enter(_ address: String) {
            app.buttons["connection.clear"].tap()
            let field = app.textFields["connection.address"]
            field.tap(); field.typeText(address + "\n")
            app.buttons["connection.save"].tap()
        }
        openConnection()
        XCTAssertEqual(app.textFields["connection.address"].value as? String, "https://old-connection.invalid")
        enter("https://rejected-connection.invalid/bookpocket")
        XCTAssertTrue(app.staticTexts["connection.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["connection.error"].label.contains("rejected"))
        app.navigationBars["Companion connection"].buttons["Cancel"].tap()
        openConnection()
        XCTAssertEqual(app.textFields["connection.address"].value as? String, "https://old-connection.invalid", "A rejected public connection must retain the paired address")
        enter("https://new-connection.invalid:10000/bookpocket/")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Companion connection"])], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["connection.edit"].exists, "Changing the address must keep the existing pairing")
        openConnection()
        XCTAssertEqual(app.textFields["connection.address"].value as? String, "https://new-connection.invalid:10000/bookpocket")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Verified companion address change — isolated transport fixture"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testLargestDynamicTypeKeepsListenAndReaderControlsUsable() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--content-size-probe", "-playbackRate", "1",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let probe = app.descendants(matching: .any).matching(identifier: "test.content-size").firstMatch
        let expected = "UIKit=\(UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue); SwiftUI=accessibility5"
        let actualTrait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: probe)
        guard XCTWaiter.wait(for: [actualTrait], timeout: 30) == .completed else {
            XCTFail("Largest Dynamic Type must actually reach UIKit and SwiftUI; observed \(String(describing: probe.value))")
            return
        }
        let traitEvidence = XCTAttachment(string: (probe.value as? String) ?? "Missing actual trait")
        traitEvidence.name = "Verified native and SwiftUI accessibility text size"; traitEvidence.lifetime = .keepAlways; add(traitEvidence)
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30))
        assertEmptyListenFits(app, name: "Obsidian empty Listen largest text portrait")
        let emptyPosition = app.staticTexts["listen.empty.help"].frame
        app.swipeUp()
        XCTAssertEqual(app.staticTexts["listen.empty.help"].frame, emptyPosition, "Empty Listen must not scroll")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertEmptyListenFits(app, name: "Obsidian empty Listen largest text landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForScreenshotOrientation(landscape: false))
        app.buttons["listen.downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        let downloadsList = app.collectionViews.firstMatch
        XCTAssertTrue(downloadsList.waitForExistence(timeout: 10))
        let recording = app.buttons["listen.download.transport-job"]
        // Auxiliary lists may scroll: at the largest text size the preceding
        // take is taller than the compact screen, so this row is virtualized.
        for _ in 0..<4 {
            if recording.exists && recording.isHittable { break }
            downloadsList.swipeUp()
        }
        guard recording.exists && recording.isHittable else {
            XCTFail("The exact downloaded transport job must be reachable in the Downloads list")
            return
        }
        recording.tap()
        let play = app.buttons["player.full.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertEqual(play.value as? String, "Playing"); play.tap()
        XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(app.staticTexts["listen.elapsed"].label, "Elapsed time")
        XCTAssertEqual(app.staticTexts["listen.duration"].label, "Total duration")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 90)
        XCTAssertEqual(app.sliders["listen.position"].label, "Audio position")
        XCTAssertEqual(app.buttons["listen.chapters"].label, "Chapters")
        assertDownloadedListenFits(app, name: "Obsidian largest Dynamic Type portrait")
        XCTAssertLessThanOrEqual(app.buttons["listen.chapters"].frame.maxY, app.sliders["listen.position"].frame.minY)
        XCTAssertLessThanOrEqual(play.frame.maxY, app.buttons["listen.speed"].frame.minY)
        XCTAssertLessThanOrEqual(play.frame.maxY, app.buttons["listen.sleep"].frame.minY)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertDownloadedListenFits(app, name: "Obsidian largest Dynamic Type landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForScreenshotOrientation(landscape: false))
        app.tabBars.buttons["Library"].tap()
        assertMiniPlayerAboveTabs(in: app)
        assertMinimumHitArea(app.buttons["player.mini.toggle"])
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(waitForReaderContents(app))
        for (id, label) in [("reader.previous", "Previous page"), ("reader.next", "Next page"), ("reader.speak", "Read aloud")] {
            let button = app.buttons[id]
            XCTAssertEqual(button.label, label)
            assertMinimumHitArea(button)
        }
        XCTAssertLessThanOrEqual(app.buttons["reader.previous"].frame.maxX, app.buttons["reader.speak"].frame.minX)
        XCTAssertLessThanOrEqual(app.buttons["reader.speak"].frame.maxX, app.buttons["reader.next"].frame.minX)
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        assertVisibleInk(in: paragraph)
        let reader = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        reader.name = "Obsidian reader controls at verified accessibility size"; reader.lifetime = .keepAlways; add(reader)
        app.buttons["reader.speak"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "reader.player.narrator").firstMatch.waitForExistence(timeout: 10))
        chooseReaderNarrator(app, "kyon")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled, "Unrelated transport audio must not become Kyon")
        assertReaderPlayerFits(app, name: "Obsidian reader player largest text portrait")
        assertReaderScopeChoicesFit(app, name: "Obsidian generation choices largest text portrait")
        assertReaderSettingsFit(app, name: "Obsidian playback choices largest text portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertReaderPlayerFits(app, name: "Obsidian reader player largest text landscape")
        assertReaderScopeChoicesFit(app, name: "Obsidian generation choices largest text landscape")
        assertReaderSettingsFit(app, name: "Obsidian playback choices largest text landscape")
    }

    private func chooseReaderNarrator(_ app: XCUIApplication, _ mode: String) {
        let choice = app.buttons["reader.voice." + mode]
        if !choice.exists {
            let menu = app.buttons["reader.player.narrator"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: menu)], timeout: 20), .completed)
            menu.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: choice)], timeout: 20), .completed)
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); assertMinimumHitArea(choice); choice.tap()
        if mode != "device" {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["reader.player.generate"])], timeout: 20), .completed)
        }
    }

    private func assertReaderPlayerFits(_ app: XCUIApplication, name: String) {
        let viewport = app.frame
        let surface = app.otherElements["reader.player.surface"]
        XCTAssertTrue(surface.exists)
        XCTAssertEqual(surface.scrollViews.count, 0, "The compact reader player must not scroll")
        var frames: [String] = []
        var positions: [String: CGRect] = [:]
        if app.buttons["reader.voice.device"].exists {
            for mode in ["device", "kyon", "cast"] { assertMinimumHitArea(app.buttons["reader.voice." + mode], viewport: viewport) }
        } else { assertMinimumHitArea(app.buttons["reader.player.narrator"], viewport: viewport) }
        for id in ["backward", "toggle", "forward", "speed", "chapters", "sleep", "generate", "details"] {
            let control = app.buttons["reader.player." + id]
            let frame = control.frame; positions[id] = frame
            if control.isEnabled { assertMinimumHitArea(control, frame: frame, viewport: viewport) }
            else {
                XCTAssertTrue(control.exists && viewport.contains(frame))
                XCTAssertGreaterThanOrEqual(frame.width + 0.001, 44)
                XCTAssertGreaterThanOrEqual(frame.height + 0.001, 44)
            }
            frames.append("\(id): \(frame)")
        }
        XCTAssertLessThanOrEqual(positions["backward"]!.maxX, positions["toggle"]!.minX)
        XCTAssertLessThanOrEqual(positions["toggle"]!.maxX, positions["forward"]!.minX)
        XCTAssertFalse(positions["toggle"]!.intersects(positions["generate"]!), "Transport and actions must not overlap in either layout")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let geometry = XCTAttachment(string: frames.joined(separator: "\n")); geometry.name = name + " geometry"; geometry.lifetime = .keepAlways; add(geometry)
    }

    private func assertReaderScopeChoicesFit(_ app: XCUIApplication, name: String) {
        app.buttons["reader.player.generate"].tap()
        XCTAssertTrue(app.buttons["reader.generate.page"].waitForExistence(timeout: 5))
        for scope in ["page", "chapter"] { assertMinimumHitArea(app.buttons["reader.generate." + scope]) }
        XCTAssertFalse(app.buttons["reader.generate.page"].frame.intersects(app.buttons["reader.generate.chapter"].frame))
        XCTAssertEqual(app.otherElements["reader.player.surface"].scrollViews.count, 0)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["reader.player.choice.back"].tap()
        XCTAssertTrue(app.buttons["reader.player.generate"].waitForExistence(timeout: 5))
    }
    private func assertReaderSettingsFit(_ app: XCUIApplication, name: String) {
        app.buttons["reader.player.speed"].tap()
        XCTAssertTrue(app.buttons["1.5×"].waitForExistence(timeout: 5))
        for title in ["0.75×", "1×", "1.25×", "1.5×", "2×"] { assertMinimumHitArea(app.buttons[title]) }
        XCTAssertEqual(app.otherElements["reader.player.surface"].scrollViews.count, 0)
        let rates = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rates.name = name + " rates"; rates.lifetime = .keepAlways; add(rates)
        app.buttons["1.5×"].tap()
        XCTAssertEqual(app.buttons["reader.player.speed"].value as? String, "1.5×")
        app.buttons["reader.player.sleep"].tap()
        XCTAssertTrue(app.buttons["5 minutes"].waitForExistence(timeout: 5))
        for title in ["Off", "5 minutes", "15 minutes", "30 minutes", "60 minutes"] { assertMinimumHitArea(app.buttons[title]) }
        let timer = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        timer.name = name + " timer"; timer.lifetime = .keepAlways; add(timer)
        app.buttons["5 minutes"].tap()
        XCTAssertEqual(app.buttons["reader.player.sleep"].value as? String, "On")
        app.buttons["reader.player.sleep"].tap(); app.buttons["Off"].tap()
        XCTAssertEqual(app.buttons["reader.player.sleep"].value as? String, "Off")
    }

    func testReaderPlayerKeepsNarratorsAndOfflineTakesSeparate() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", "-playbackRate", "1"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); XCTAssertTrue(book.label.contains("not speech")); book.tap()
        XCTAssertTrue(waitForReaderContents(app))
        let original = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        guard assertVisibleInk(in: original) else { return }
        app.buttons["reader.speak"].tap()
        let play = app.buttons["reader.player.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertEqual(play.value as? String, "Paused")
        chooseReaderNarrator(app, "cast")
        XCTAssertFalse(play.isEnabled, "Full cast from the second chapter cannot play on this page")
        chooseReaderNarrator(app, "kyon")
        XCTAssertTrue(play.isEnabled); XCTAssertEqual(play.value as? String, "Paused", "Selecting a narrator must not play")
        XCTAssertEqual(app.staticTexts["reader.player.readiness"].label, "Ready offline")
        let selectedDuration = audioSeconds(app.staticTexts["reader.player.duration"])
        XCTAssertGreaterThan(selectedDuration, 0)
        assertReaderPlayerFits(app, name: "Obsidian reader with matching offline take")
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 10), .completed)
        play.tap(); XCTAssertEqual(play.value as? String, "Paused")
        let slider = app.sliders["reader.player.seek"]
        XCTAssertTrue(slider.exists && slider.isHittable); slider.adjust(toNormalizedSliderPosition: 0.5)
        // XCTest's native slider gesture is best effort. Assert the real global
        // result and clock agreement, rather than an arbitrary midpoint band.
        let soughtSeconds = audioSeconds(app.staticTexts["reader.player.elapsed"])
        XCTAssertGreaterThan(soughtSeconds, 0); XCTAssertLessThan(soughtSeconds, selectedDuration)
        XCTAssertEqual(Double(slider.normalizedSliderPosition) * selectedDuration, soughtSeconds, accuracy: 1)
        assertReaderSettingsFit(app, name: "Obsidian offline playback choices")
        XCTAssertEqual(play.value as? String, "Paused", "Adjusting speed and timer must not resume paused audio")
        app.navigationBars["Read aloud"].buttons["Done"].tap()
        app.buttons["reader.close"].tap(); app.tabBars.buttons["Listen"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), selectedDuration, accuracy: 1, "Listen must retain the complete selected page timeline")
        XCTAssertEqual(app.buttons["listen.speed"].value as? String, "1.5×")
        app.tabBars.buttons["Library"].tap(); book.tap(); XCTAssertTrue(waitForReaderContents(app))
        app.buttons["reader.speak"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isEnabled)
        app.buttons["reader.player.chapters"].tap()
        let sourceChapter = app.buttons["reader.player.chapter.1"]
        XCTAssertTrue(sourceChapter.waitForExistence(timeout: 10)); sourceChapter.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: play)], timeout: 20), .completed, "Paused chapter-one audio must become unavailable after source navigation while the panel stays open")
        XCTAssertEqual(app.buttons["reader.player.chapters"].value as? String, "Across the Bridge")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "No audio for this page"), object: app.staticTexts["reader.player.readiness"])], timeout: 20), .completed)
        app.navigationBars["Read aloud"].buttons["Done"].tap()
        let second = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "At dawn, Mira crossed the bridge")).firstMatch
        guard assertVisibleInk(in: second) else { return }
        app.buttons["reader.speak"].tap()
        chooseReaderNarrator(app, "cast")
        XCTAssertTrue(play.isEnabled); XCTAssertEqual(play.value as? String, "Paused")
        app.buttons["reader.player.chapters"].tap()
        let take = app.buttons["reader.player.chapter.reader-tone-job-1:reader-chapter-1"]
        XCTAssertTrue(take.waitForExistence(timeout: 10)); XCTAssertTrue(take.label.contains("Full chapter")); take.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 10), .completed)
        play.tap()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "Obsidian full-cast offline chapter transport fixture"; screenshot.lifetime = .keepAlways; add(screenshot)
        chooseReaderNarrator(app, "kyon")
        XCTAssertFalse(play.isEnabled, "Kyon from the first chapter cannot resume on this unrelated page")
        chooseReaderNarrator(app, "device")
        XCTAssertTrue(play.isEnabled); XCTAssertEqual(play.value as? String, "Paused", "Switching to on-device speech must not start it")
        app.navigationBars["Read aloud"].buttons["Done"].tap()
        app.buttons["reader.close"].tap(); app.tabBars.buttons["Listen"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 480, "The four-passage full chapter has one total duration")
    }

    func testContinuousPageRecordingShowsTotalTimeAndSeeksAcrossPassages() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        let arguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", "--reader-continuous-fixture", "-playbackRate", "0.5"]
        app.launchArguments = arguments
        XCUIDevice.shared.orientation = .portrait; app.launch()
        openContinuousPage(app)
        let play = app.buttons["reader.player.toggle"]
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.duration"]), 124)
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.elapsed"]), 0)
        assertReaderTimelineFits(app, name: "Obsidian continuous page ready with full duration")
        play.tap()
        let crossed = NSPredicate { _, _ in self.audioSeconds(app.staticTexts["reader.player.elapsed"]) >= 5 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: crossed, object: nil)], timeout: 35), .completed, "Playback must pass the four-second asset boundary on one global clock")
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.duration"]), 124)
        XCTAssertEqual(play.value as? String, "Playing")
        play.tap(); XCTAssertEqual(play.value as? String, "Paused")
        let slider = app.sliders["reader.player.seek"]
        slider.adjust(toNormalizedSliderPosition: 0.8)
        let seek = audioSeconds(app.staticTexts["reader.player.elapsed"])
        XCTAssertGreaterThanOrEqual(seek, 64, "The slider can seek directly into the third backend passage")
        XCTAssertEqual(Double(slider.normalizedSliderPosition) * 124, seek, accuracy: 1)
        app.buttons["reader.player.backward"].tap(); XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.elapsed"]), seek - 15, accuracy: 1)
        app.buttons["reader.player.forward"].tap(); XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.elapsed"]), seek, accuracy: 1)
        slider.adjust(toNormalizedSliderPosition: 0.55)
        assertReaderTimelineFits(app, name: "Obsidian continuous page paused across passage boundary")
        XCTAssertEqual(play.value as? String, "Paused")
        XCUIDevice.shared.orientation = .landscapeRight; XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertReaderTimelineFits(app, name: "Obsidian continuous page timeline landscape")
        XCUIDevice.shared.orientation = .portrait; XCTAssertTrue(waitForScreenshotOrientation(landscape: false))
        app.buttons["reader.scope.chapter"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)], timeout: 20), .completed)
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.duration"]), 184, "Changing scope prepares the complete chapter, not the paused page clock")
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.elapsed"]), 0); XCTAssertEqual(play.value as? String, "Paused")
        play.tap(); XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.duration"]), 184)
        play.tap(); assertReaderTimelineFits(app, name: "Obsidian continuous whole chapter timeline")
        app.navigationBars["Read aloud"].buttons["Done"].tap(); app.buttons["reader.close"].tap(); app.tabBars.buttons["Listen"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 184)
        XCTAssertEqual(app.buttons["player.full.toggle"].value as? String, "Paused")
        assertDownloadedListenFits(app, name: "Obsidian continuous chapter shared Listen timeline")
    }
    func testContinuousRecordingTimelineFitsLargestTextSizes() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", "--reader-continuous-fixture", "-playbackRate", "0.5", "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        XCUIDevice.shared.orientation = .portrait
        app.launch(); openContinuousPage(app)
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.duration"]), 124)
        XCTAssertEqual(audioSeconds(app.staticTexts["reader.player.elapsed"]), 0)
        XCTAssertEqual(app.buttons["reader.player.toggle"].value as? String, "Paused", "Accessibility layout verification must not start playback")
        assertReaderTimelineFits(app, name: "Obsidian continuous page timeline largest text")
        XCUIDevice.shared.orientation = .landscapeRight; XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertReaderTimelineFits(app, name: "Obsidian continuous page timeline largest text landscape")
        XCUIDevice.shared.orientation = .portrait
    }
    private func openContinuousPage(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap(); XCTAssertTrue(waitForReaderContents(app))
        app.buttons["reader.speak"].tap(); chooseReaderNarrator(app, "kyon")
        app.buttons["reader.player.saved"].tap()
        let page = app.buttons["reader.saved.reader-continuous-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 10)); XCTAssertTrue(page.label.contains("Ready offline")); page.tap()
        XCTAssertTrue(app.buttons["reader.player.toggle"].waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["reader.player.toggle"].isEnabled)
    }
    private func assertReaderTimelineFits(_ app: XCUIApplication, name: String) {
        assertReaderPlayerFits(app, name: name)
        let slider = app.sliders["reader.player.seek"], elapsed = app.staticTexts["reader.player.elapsed"], duration = app.staticTexts["reader.player.duration"]
        let viewport = app.frame, sliderFrame = slider.frame, elapsedFrame = elapsed.frame, durationFrame = duration.frame
        let toggleFrame = app.buttons["reader.player.toggle"].frame, surfaceFrame = app.otherElements["reader.player.surface"].frame
        for (text, frame) in [(elapsed, elapsedFrame), (duration, durationFrame)] { XCTAssertTrue(text.exists && text.isHittable && viewport.contains(frame)); XCTAssertGreaterThan(frame.height, 0) }
        XCTAssertLessThanOrEqual(sliderFrame.maxY, elapsedFrame.minY + 1)
        XCTAssertLessThanOrEqual(elapsedFrame.maxY, toggleFrame.minY)
        XCTAssertLessThanOrEqual(durationFrame.maxY, toggleFrame.minY)
        XCTAssertLessThanOrEqual(elapsedFrame.maxX, durationFrame.minX)
        XCTAssertGreaterThanOrEqual(surfaceFrame.maxY, viewport.maxY - 1, "The charcoal player extends to the display's bottom edge")
    }

    func testMatchingAudioRequiresExplicitAlternateTakeInsteadOfMissingMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", "--reader-alternate-takes-fixture"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch.tap()
        XCTAssertTrue(waitForReaderContents(app)); app.buttons["reader.speak"].tap()
        chooseReaderNarrator(app, "kyon")
        XCTAssertEqual(app.staticTexts["reader.player.readiness"].label, "Choose a matching take · Saved audio")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        app.buttons["reader.player.saved"].tap()
        let take = app.buttons["reader.saved.reader-alternate-job"]
        XCTAssertTrue(take.waitForExistence(timeout: 10)); XCTAssertTrue(take.label.contains("Ready offline")); take.tap()
        let play = app.buttons["reader.player.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isEnabled)
        XCTAssertEqual(play.value as? String, "Paused")
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 10), .completed)
        play.tap()
        assertReaderPlayerFits(app, name: "Obsidian explicit matching alternate audio selection")
    }
    func testSavedPageClipsPlayWithoutChapterAndPlayerReachesBottomEdge() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", "--reader-page-clips-fixture", "-playbackRate", "1"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Library"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch.tap()
        XCTAssertTrue(waitForReaderContents(app)); app.buttons["reader.speak"].tap()
        chooseReaderNarrator(app, "kyon")
        let play = app.buttons["reader.player.toggle"]
        XCTAssertFalse(play.isEnabled, "A partial clip cannot stand in for all visible words")
        let saved = app.buttons["reader.player.saved"]
        assertMinimumHitArea(saved)
        XCTAssertTrue(saved.label.contains("2 page clips")); XCTAssertTrue(saved.label.contains("Chapter not generated"))
        assertReaderPlayerFits(app, name: "Obsidian page clips without full chapter")
        // The panel's surface is the content area below its own navigation bar.
        // Its background must extend through the iPhone home indicator area.
        XCTAssertGreaterThanOrEqual(app.otherElements["reader.player.surface"].frame.maxY, app.frame.maxY - 1)
        app.buttons["reader.scope.chapter"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Chapter not generated"), object: app.staticTexts["reader.player.readiness"])], timeout: 20), .completed)
        XCTAssertFalse(play.isEnabled); saved.tap()
        let localClip = app.buttons["reader.saved.reader-page-job-0"]
        let remoteClip = app.buttons["reader.saved.reader-page-job-1"]
        XCTAssertTrue(localClip.waitForExistence(timeout: 10)); XCTAssertTrue(localClip.label.contains("Ready offline"))
        XCTAssertTrue(remoteClip.label.contains("On PC"))
        XCTAssertTrue(app.buttons["reader.saved.download.reader-page-job-1"].exists)
        let browser = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); browser.name = "Obsidian saved page audio and remote download"; browser.lifetime = .keepAlways; add(browser)
        app.buttons["reader.saved.download.reader-page-job-1"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reconnect your PC and retry the download")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(remoteClip.label.contains("On PC"), "A failed download cannot make PC-only audio ready")
        localClip.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isEnabled)
        XCTAssertEqual(play.value as? String, "Paused", "Selecting saved audio must not start it")
        XCTAssertTrue(app.staticTexts["reader.player.readiness"].label.contains("Saved page clip"))
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 10), .completed)
        play.tap()
        assertReaderPlayerFits(app, name: "Obsidian selected saved page playback to bottom edge")
        XCTAssertGreaterThanOrEqual(app.otherElements["reader.player.surface"].frame.maxY, app.frame.maxY - 1)
        assertReaderScopeChoicesFit(app, name: "Obsidian page or chapter generation chooser")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertReaderPlayerFits(app, name: "Obsidian saved page player landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForScreenshotOrientation(landscape: false))
        saved.tap(); XCTAssertTrue(remoteClip.waitForExistence(timeout: 10)); remoteClip.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertFalse(play.isEnabled)
        XCTAssertTrue(app.buttons["reader.player.download"].isHittable)
        assertReaderPlayerFits(app, name: "Obsidian PC-only page clip awaiting download")
        chooseReaderNarrator(app, "cast")
        XCTAssertFalse(play.isEnabled); XCTAssertTrue(saved.label.contains("0 page clips"), "Kyon clips cannot appear as full cast")
    }
    private func startReaderSpeech(_ app: XCUIApplication) {
        app.buttons["reader.speak"].tap()
        let play = app.buttons["reader.player.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(play.value as? String, "Paused", "Opening Read aloud must not start speech")
        XCTAssertTrue(app.buttons["reader.voice.device"].exists || app.buttons["reader.player.narrator"].label.contains("On-device"))
        XCTAssertTrue(play.isEnabled); play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 20), .completed, "Actual on-device speech must start")
        XCTAssertEqual(app.buttons["reader.player.backward"].label, "Previous passage")
        app.navigationBars["Read aloud"].buttons["Done"].tap()
    }

    private func assertMinimumHitArea(_ element: XCUIElement, frame capturedFrame: CGRect? = nil, viewport capturedViewport: CGRect? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let frame = capturedFrame ?? element.frame, viewport = capturedViewport ?? XCUIApplication().frame
        XCTAssertTrue(element.exists && element.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.width + 0.001, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 0.001, 44, file: file, line: line)
        XCTAssertTrue(viewport.contains(frame), file: file, line: line)
    }

    private func assertEmptyListenFits(_ app: XCUIApplication, name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.scrollViews.count, 0, "Empty Listen must not create a scrolling container", file: file, line: line)
        let title = app.staticTexts["listen.empty.title"]
        let help = app.staticTexts["listen.empty.help"]
        XCTAssertEqual(title.label, "Ready to listen", file: file, line: line)
        XCTAssertEqual(help.label, "Open a book or choose Downloads above.", file: file, line: line)
        for text in [title, help] {
            XCTAssertTrue(text.exists && text.isHittable && app.frame.contains(text.frame), file: file, line: line)
            XCTAssertGreaterThan(text.frame.height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(text.frame.minY, app.navigationBars["Listen"].frame.maxY, file: file, line: line)
            XCTAssertLessThanOrEqual(text.frame.maxY, app.tabBars.buttons["Listen"].frame.minY, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(title.frame.maxY, help.frame.minY, file: file, line: line)
        XCTAssertTrue(app.buttons["listen.downloads"].isHittable, file: file, line: line)
        for tab in ["Library", "Listen", "Studio"] { XCTAssertTrue(app.tabBars.buttons[tab].isHittable, file: file, line: line) }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testDownloadedAudioFitsOneScreenAndSelectsOfflineChapters() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "-playbackRate", "1"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        // The DEBUG fixture installs original PCM tones, not synthesized speech,
        // in isolated unpaired stores and opens Listen only after installation.
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 30))
        app.buttons["listen.downloads"].tap()
        let recording = app.buttons["listen.download.transport-job"]
        XCTAssertTrue(recording.waitForExistence(timeout: 10)); recording.tap()
        let play = app.buttons["player.full.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(play.value as? String, "Playing")
        play.tap()
        XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(app.buttons["listen.chapters"].value as? String, "Tone one — 90 seconds")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 90)
        let position = app.sliders["listen.position"]
        XCTAssertTrue(position.exists && position.isHittable)
        position.adjust(toNormalizedSliderPosition: 0.5)
        // XCTest's slider gesture is best effort. Verify its actual result and
        // the player binding, then measure exact skips from that real position.
        let soughtSeconds = audioSeconds(app.staticTexts["listen.elapsed"])
        XCTAssertGreaterThanOrEqual(soughtSeconds, 30)
        XCTAssertLessThanOrEqual(soughtSeconds, 60)
        XCTAssertEqual(Double(position.normalizedSliderPosition) * 90, soughtSeconds, accuracy: 1, "Slider accessibility position must agree with the actual elapsed time")
        let seekEvidence = XCTAttachment(string: "Elapsed: \(soughtSeconds)s; slider value: \(String(describing: position.value)); normalized: \(position.normalizedSliderPosition)")
        seekEvidence.name = "Actual offline audio seek position"; seekEvidence.lifetime = .keepAlways; add(seekEvidence)
        app.buttons["listen.backward"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.elapsed"]), soughtSeconds - 15, accuracy: 1)
        app.buttons["listen.forward"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.elapsed"]), soughtSeconds, accuracy: 1)
        app.buttons["listen.speed"].tap()
        XCTAssertTrue(app.buttons["1.5×"].waitForExistence(timeout: 5)); app.buttons["1.5×"].tap()
        XCTAssertEqual(app.buttons["listen.speed"].value as? String, "1.5×")
        assertDownloadedListenFits(app, name: "Obsidian offline transport tone portrait")
        let frame = play.frame
        app.swipeUp()
        XCTAssertEqual(play.frame, frame, "Downloaded player must also fit without scrolling")
        app.buttons["listen.chapters"].tap()
        XCTAssertTrue(app.navigationBars["Chapters"].waitForExistence(timeout: 10))
        let original = app.buttons["listen.chapter.transport-job:transport-chapter-0"]
        XCTAssertTrue(original.exists); XCTAssertTrue(original.label.contains("Full chapter"))
        let excerpt = app.buttons["listen.chapter.transport-excerpt-job:transport-chapter-0"]
        XCTAssertTrue(excerpt.exists); XCTAssertTrue(excerpt.label.contains("Excerpt"))
        XCTAssertFalse(app.buttons["listen.chapter.transport-job:transport-chapter-2"].exists, "An asset with no local file cannot be offered as an offline chapter")
        XCTAssertFalse(app.staticTexts["Different book chapter"].exists)
        let next = app.buttons["listen.chapter.transport-second-job:transport-chapter-1"]
        XCTAssertTrue(next.exists && next.isHittable); next.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Tone two — 120 seconds"), object: app.buttons["listen.chapters"])], timeout: 10), .completed)
        XCTAssertEqual(play.value as? String, "Playing", "Selecting downloaded chapter must start the real local recording")
        play.tap()
        XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 120)
        XCTAssertLessThan(audioSeconds(app.staticTexts["listen.elapsed"]), 15, "Chapter selection must start at its beginning, not the preceding seek position")
        XCTAssertEqual(app.buttons["listen.speed"].value as? String, "1.5×")
        assertDownloadedListenFits(app, name: "Obsidian offline transport selected chapter")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertDownloadedListenFits(app, name: "Obsidian offline transport tone landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForScreenshotOrientation(landscape: false))
        let pausedSeconds = audioSeconds(app.staticTexts["listen.elapsed"])
        let pausedSliderPosition = position.normalizedSliderPosition
        XCTAssertEqual(play.value as? String, "Paused")
        app.tabBars.buttons["Studio"].tap()
        XCTAssertTrue(app.buttons["studio.primary"].waitForExistence(timeout: 10))
        XCTAssertEqual(playbackMiniState(app), "Paused")
        // This is the normal unpaired Studio action, never a fabricated PC-ready state.
        XCTAssertTrue(app.buttons["studio.primary"].label.contains("Pair"))
        app.tabBars.buttons["Listen"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 120)
        XCTAssertEqual(play.value as? String, "Paused")
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.elapsed"]), pausedSeconds, "Switching tabs must preserve the paused audio position")
        XCTAssertEqual(position.normalizedSliderPosition, pausedSliderPosition, accuracy: 0.0001)
        app.buttons["listen.chapters"].tap()
        XCTAssertTrue(excerpt.waitForExistence(timeout: 10))
        XCTAssertTrue(excerpt.label.contains("Excerpt")); excerpt.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Tone one — 90 seconds"), object: app.buttons["listen.chapters"])], timeout: 10), .completed)
        XCTAssertEqual(play.value as? String, "Playing", "An alternate excerpt requires an explicit selection")
        play.tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 90)
        app.buttons["listen.chapters"].tap()
        XCTAssertTrue(excerpt.waitForExistence(timeout: 10))
        XCTAssertTrue(excerpt.label.contains("Current take"))
        XCTAssertFalse(original.label.contains("Current take"))
        let choices = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        choices.name = "Obsidian book chapters with explicit offline takes and excerpt"; choices.lifetime = .keepAlways; add(choices)
        app.buttons["Done"].tap()
    }

    private func audioSeconds(_ element: XCUIElement) -> Double {
        let value = (element.value as? String) ?? element.label
        let components = value.split(separator: ":").compactMap { Double($0) }
        guard components.count == 2 else { XCTFail("Expected an actual minute:second playback value, received \(value)"); return -.infinity }
        return components[0] * 60 + components[1]
    }

    private func playbackMiniState(_ app: XCUIApplication) -> String? {
        assertMiniPlayerAboveTabs(in: app)
        return app.buttons["player.mini.toggle"].value as? String
    }

    private func assertDownloadedListenFits(_ app: XCUIApplication, name: String, file: StaticString = #filePath, line: UInt = #line) {
        assertListenFits(app, name: name, file: file, line: line)
        let slider = app.sliders["listen.position"]
        XCTAssertTrue(slider.exists && slider.isHittable, file: file, line: line)
        XCTAssertGreaterThan(slider.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThan(slider.frame.height, 0, file: file, line: line)
        XCTAssertTrue(app.frame.contains(slider.frame), file: file, line: line)
        XCTAssertLessThanOrEqual(slider.frame.maxY, app.buttons["player.full.toggle"].frame.minY, "Seek control must not overlap playback controls", file: file, line: line)
        for id in ["listen.elapsed", "listen.duration"] {
            let label = app.staticTexts[id]
            XCTAssertTrue(label.exists && app.frame.contains(label.frame), file: file, line: line)
            XCTAssertLessThanOrEqual(label.frame.maxY, app.buttons["player.full.toggle"].frame.minY, file: file, line: line)
        }
        let geometry = XCTAttachment(string: "Seek slider: \(slider.frame)\nElapsed: \(app.staticTexts["listen.elapsed"].frame)\nDuration: \(app.staticTexts["listen.duration"].frame)")
        geometry.name = name + " audio timeline geometry"; geometry.lifetime = .keepAlways; add(geometry)
    }

    func testListenFitsOneScreenAndSelectsChapters() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--import-fixture", "-playbackRate", "0.75"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30)); book.tap()
        XCTAssertTrue(waitForReaderContents(app)); app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["The Lantern"].waitForExistence(timeout: 10)); app.buttons["The Lantern"].tap()
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30)); assertVisibleInk(in: paragraph)
        startReaderSpeech(app)
        app.buttons["reader.close"].tap(); app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["listen.chapters"].waitForExistence(timeout: 10))
        let play = app.buttons["player.full.toggle"]
        XCTAssertEqual(play.value as? String, "Playing")
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Paused"), object: play)], timeout: 10), .completed)
        assertListenFits(app, name: "Obsidian Listen portrait before chapter selection")
        let position = app.buttons["player.full.toggle"].frame
        app.swipeUp()
        XCTAssertEqual(app.buttons["player.full.toggle"].frame, position, "The player surface must not scroll")
        app.buttons["listen.chapters"].tap()
        XCTAssertTrue(app.navigationBars["Chapters"].waitForExistence(timeout: 10))
        let chapter = app.buttons["Across the Bridge"]
        XCTAssertTrue(chapter.exists && chapter.isHittable); chapter.tap()
        let selected = app.buttons["listen.chapters"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Across the Bridge"), object: selected)], timeout: 20), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 15), .completed)
        assertListenFits(app, name: "Obsidian Listen selected chapter")
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Paused"), object: play)], timeout: 10), .completed)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true), "Device capture must finish rotating before landscape evidence")
        assertListenFits(app, name: "Obsidian Listen landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(waitForScreenshotOrientation(landscape: false))
        app.tabBars.buttons["Library"].tap(); book.tap()
        // Reopening creates a new WebKit spread. Toolbar existence alone can
        // precede its first rendered viewport, especially on a loaded CI host.
        XCTAssertTrue(waitForReaderContents(app, timeout: 60))
        let target = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Across the Bridge")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 60)); assertVisibleInk(in: target)
    }

    private func assertListenFits(_ app: XCUIApplication, name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.scrollViews.count, 0, "Main Listen must fit without a scrolling container", file: file, line: line)
        let tabTop = app.tabBars.buttons["Listen"].frame.minY
        var geometry: [String] = ["Screen: \(app.frame)", "Tabs begin: \(tabTop)"]
        for id in ["listen.chapters", "listen.backward", "player.full.toggle", "listen.forward", "listen.speed", "listen.sleep"] {
            let control = app.buttons[id]
            XCTAssertTrue(control.exists && control.isHittable, id, file: file, line: line)
            // AX may report a 44pt transformed rect as 43.99999999999994.
            XCTAssertGreaterThanOrEqual(control.frame.width + 0.001, 44, id, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.height + 0.001, 44, id, file: file, line: line)
            XCTAssertTrue(app.frame.contains(control.frame), "\(id) must fit on screen", file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxY, tabTop, "\(id) must remain above tabs", file: file, line: line)
            geometry.append("\(id): \(control.frame)")
        }
        XCTAssertTrue(app.buttons["listen.downloads"].isHittable, file: file, line: line)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let frames = XCTAttachment(string: geometry.joined(separator: "\n")); frames.name = name + " geometry"; frames.lifetime = .keepAlways; add(frames)
    }

    func testCurrentPageNarrationCapturesRealEPUBBeforePresentingSheet() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--import-fixture"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30)); book.tap()
        // The compact cold simulator needed about 70 seconds to report its
        // first viewport. Keep the real enabled/hittable readiness predicate.
        XCTAssertTrue(waitForReaderContents(app, timeout: 90))
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        // Cold WebKit exposes the toolbar before revealing its initial spread.
        // Do not open another presentation until the original page is painted.
        guard assertVisibleInk(in: paragraph) else { return }
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["The Lantern"].waitForExistence(timeout: 10)); app.buttons["The Lantern"].tap()
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30))
        guard assertVisibleInk(in: paragraph) else { return }
        app.buttons["reader.speak"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "reader.player.narrator").firstMatch.waitForExistence(timeout: 10))
        chooseReaderNarrator(app, "kyon")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        assertReaderPlayerFits(app, name: "Obsidian segmented narrator without generated audio")
        app.buttons["reader.player.generate"].tap()
        let page = app.buttons["reader.generate.page"]
        XCTAssertTrue(app.buttons["reader.generate.chapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        assertMinimumHitArea(page); assertMinimumHitArea(app.buttons["reader.generate.chapter"])
        let choices = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        choices.name = "Obsidian page and chapter generation choices"; choices.lifetime = .keepAlways; add(choices)
        page.tap()
        XCTAssertFalse(app.navigationBars["Narration"].exists, "Choosing scope must return to the compact player, not force a full-screen preview")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Pair your PC"), object: app.staticTexts["reader.player.readiness"])], timeout: 20), .completed)
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        app.buttons["reader.player.details"].tap()
        let preview = app.staticTexts["reader.generation.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(preview.label.contains("Mira opened the brass lantern"))
        XCTAssertFalse(preview.label.contains("Across the Bridge"), "Current page must not include the next chapter")
        XCTAssertTrue(app.buttons["Pair your PC"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Obsidian exact current page narration preview"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["Narration"].buttons["Done"].tap()
        app.navigationBars["Read aloud"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["reader.speak"].waitForExistence(timeout: 10))
        assertVisibleInk(in: paragraph)
    }

    func testNarrationMiniPlayerLeavesNativeTabsVisibleAndUsable() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        // Use a real installed Apple voice at the slowest speed exposed in the app.
        app.launchArguments = ["--uitesting", "--import-fixture", "-playbackRate", "0.75"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        XCTAssertTrue(waitForReaderContents(app))
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 10))
        app.buttons["The Lantern"].tap()
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30))
        assertVisibleInk(in: paragraph)
        startReaderSpeech(app)
        app.buttons["reader.close"].tap()

        assertMiniPlayerAboveTabs(in: app)
        XCTAssertEqual(app.buttons["player.mini.toggle"].value as? String, "Playing")
        let active = XCTAttachment(screenshot: app.screenshot())
        active.name = "Obsidian playing narration above native tabs"; active.lifetime = .keepAlways; add(active)

        app.tabBars.buttons["Studio"].tap()
        XCTAssertTrue(app.navigationBars["Studio"].waitForExistence(timeout: 10))
        assertMiniPlayerAboveTabs(in: app)
        XCTAssertEqual(app.buttons["player.mini.toggle"].value as? String, "Playing", "Changing tabs must preserve speech")
        app.tabBars.buttons["Connection"].tap()
        XCTAssertTrue(app.buttons["connection.pair"].waitForExistence(timeout: 10))
        assertMiniPlayerAboveTabs(in: app)
        XCTAssertEqual(app.buttons["player.mini.toggle"].value as? String, "Playing")
        let connectionPlayer = XCTAttachment(screenshot: app.screenshot())
        connectionPlayer.name = "Obsidian Connection with active mini player"; connectionPlayer.lifetime = .keepAlways; add(connectionPlayer)
        app.tabBars.buttons["Listen"].tap()
        let fullPlayer = app.buttons["player.full.toggle"]
        XCTAssertTrue(fullPlayer.waitForExistence(timeout: 10))
        XCTAssertEqual(fullPlayer.value as? String, "Playing")
        fullPlayer.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Paused"), object: fullPlayer)], timeout: 10), .completed)

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        assertMiniPlayerAboveTabs(in: app)
        XCTAssertEqual(app.buttons["player.mini.toggle"].value as? String, "Paused")
        let paused = XCTAttachment(screenshot: app.screenshot())
        paused.name = "Obsidian paused narration above native tabs"; paused.lifetime = .keepAlways; add(paused)
        app.buttons["player.mini.open"].tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 10))
        XCTAssertEqual(fullPlayer.value as? String, "Paused")
    }

    private func assertMiniPlayerAboveTabs(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let mini = app.otherElements["player.mini"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10), file: file, line: line)
        let open = app.buttons["player.mini.open"]
        let toggle = app.buttons["player.mini.toggle"]
        for control in [open, toggle] {
            XCTAssertTrue(control.exists && control.isHittable, "Mini player control must remain visible and tappable", file: file, line: line)
            XCTAssertGreaterThan(control.frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(control.frame.height, 0, file: file, line: line)
            XCTAssertTrue(app.frame.contains(control.frame), "Mini player control must remain on screen", file: file, line: line)
        }
        // The inset's AX container includes its background through the bottom safe area.
        // Measure the actual interactive row, not that decorative background envelope.
        let controlsFrame = open.frame.union(toggle.frame)
        var geometry = ["Container: \(mini.frame)", "Open control: \(open.frame)", "Playback control: \(toggle.frame)", "Interactive row: \(controlsFrame)"]
        for name in ["Library", "Listen", "Studio", "Connection"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.exists && tab.isHittable, "\(name) must remain visible and tappable", file: file, line: line)
            XCTAssertGreaterThan(tab.frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(tab.frame.height, 0, file: file, line: line)
            XCTAssertTrue(app.frame.contains(tab.frame), "\(name) must remain on screen", file: file, line: line)
            XCTAssertLessThanOrEqual(controlsFrame.maxY, tab.frame.minY, "Mini player controls must sit above \(name), without overlap", file: file, line: line)
            geometry.append("\(name) tab: \(tab.frame)")
        }
        let attachment = XCTAttachment(string: geometry.joined(separator: "\n"))
        attachment.name = "Mini player and native tab geometry"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testImportedEPUBOpensAndContentsWorkOffline() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--import-fixture"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        XCTAssertTrue(waitForReaderContents(app))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        let firstParagraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        XCTAssertTrue(firstParagraph.waitForExistence(timeout: 30))
        assertVisibleInk(in: firstParagraph)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Obsidian reader"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 10))
        app.buttons["Across the Bridge"].tap()
        let nextChapter = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Across the Bridge")).firstMatch
        XCTAssertTrue(nextChapter.waitForExistence(timeout: 15))
        assertVisibleInk(in: nextChapter)
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Obsidian library"; library.lifetime = .keepAlways; add(library)
        book.tap()
        XCTAssertTrue(nextChapter.waitForExistence(timeout: 15))
        assertVisibleInk(in: nextChapter)
        app.buttons["reader.close"].tap()
        app.tabBars.buttons["Studio"].tap()
        XCTAssertTrue(app.buttons["studio.primary"].waitForExistence(timeout: 10))
        let studio = XCTAttachment(screenshot: app.screenshot())
        studio.name = "Obsidian studio"; studio.lifetime = .keepAlways; add(studio)
    }

    /// WebKit exposes accessibility text before Readium finishes revealing its spread.
    /// Require actual dark glyph pixels on the fixture's cream page, not just DOM presence.
    @discardableResult private func assertVisibleInk(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let rendered = NSPredicate { _, _ in
            guard element.exists, element.isHittable,
                  let image = element.screenshot().image.cgImage else { return false }
            let width = image.width, height = image.height
            guard width > 10, height > 10 else { return false }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let count = pixels.withUnsafeMutableBytes { buffer -> Int in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                let bytes = buffer.bindMemory(to: UInt8.self)
                return stride(from: 0, to: bytes.count, by: 4).reduce(0) { result, index in
                    result + (bytes[index] < 140 && bytes[index + 1] < 140 && bytes[index + 2] < 140 && bytes[index + 3] > 200 ? 1 : 0)
                }
            }
            return count > 30
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 30)
        if result != .completed {
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Reader paint timeout screen"; screen.lifetime = .keepAlways; add(screen)
            let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
            hierarchy.name = "Reader paint timeout hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "EPUB text must be visibly painted, not only present in accessibility", file: file, line: line)
        return result == .completed
    }

    private func waitForReaderContents(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let button = app.buttons["reader.contents"]
        let ready = NSPredicate { _, _ in button.exists && button.isEnabled && button.isHittable }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout) == .completed
    }

    private func waitForScreenshotOrientation(landscape: Bool) -> Bool {
        var consecutiveMatches = 0
        let ready = NSPredicate { _, _ in
            let size = XCUIScreen.main.screenshot().image.size
            let matches = landscape ? size.width > size.height : size.height > size.width
            consecutiveMatches = matches ? consecutiveMatches + 1 : 0
            return consecutiveMatches >= 2
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15) == .completed
    }
}
