import XCTest
import UIKit

/// Actual native view/controller tests using an explicitly simulated,
/// authenticated DEBUG companion. These do not claim model or audio quality.
final class ManageAudiobookUITests: XCTestCase {
    func testManageAudiobookAnalysisProgressAndChapterSetupRemainScoped() {
        executionTimeAllowance = 300
        let app = makeApp(); app.launch(); openManage(app)
        chooseCast(app)
        XCTAssertEqual(app.buttons["manage.characters"].value as? String, "Analyze chapter first")
        XCTAssertEqual(app.buttons["manage.review"].value as? String, "Analyze chapter first")
        shot(app, "Manage audiobook — original public chapter before analysis")
        let start = app.buttons["manage.analysis.start"]
        reveal(start, app: app); assertTouchTarget(start); start.tap()
        XCTAssertTrue(app.alerts["Analyze with Google?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Only this selected chapter")).firstMatch.exists)
        app.alerts.firstMatch.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["manage.analysis.stage"].exists, "Cancelling consent must not submit analysis")
        start.tap(); acceptGoogleAnalysis(app)
        waitText(app.staticTexts["manage.analysis.count"], equals: "0 of 4 passages analyzed", seconds: 15)
        waitText(app.staticTexts["manage.analysis.percent"], equals: "0%", seconds: 10)
        XCTAssertFalse(app.buttons["reader.player.generate"].exists, "Unfinished cast analysis must not expose generation")
        shot(app, "Manage audiobook — real simulated accepted job at zero")
        waitText(app.staticTexts["manage.analysis.count"], equals: "2 of 4 passages analyzed", seconds: 30)
        waitText(app.staticTexts["manage.analysis.percent"], equals: "50%", seconds: 10)
        shot(app, "Manage audiobook — simulated job halfway with exact counts")
        let keepReading = app.buttons["manage.main"]
        reveal(keepReading, app: app); XCTAssertEqual(keepReading.label, "Keep reading"); assertTouchTarget(keepReading); keepReading.tap()
        XCTAssertTrue(app.buttons["reader.speak"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["manage.close"].exists)
        // A real process restart must discover the persisted accepted server ID;
        // the fixture rejects any duplicate/new analysis submission identity.
        app.terminate(); app.launch(); openManage(app); chooseCast(app)
        XCTAssertTrue(app.staticTexts["manage.analysis.stage"].waitForExistence(timeout: 20))
        let recoveredKeepReading = app.buttons["manage.main"]
        reveal(recoveredKeepReading, app: app)
        XCTAssertEqual(recoveredKeepReading.label, "Keep reading", "The accepted analysis must still be active after reopening")
        XCTAssertTrue(recoveredKeepReading.isEnabled, "Resuming server polling must not hold the screen's loading gate")
        assertTouchTarget(recoveredKeepReading); recoveredKeepReading.tap()
        XCTAssertTrue(app.buttons["reader.speak"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["manage.close"].exists)
        openManageFromReader(app); chooseCast(app)
        XCTAssertTrue(app.staticTexts["manage.analysis.stage"].waitForExistence(timeout: 20))
        waitText(app.staticTexts["manage.analysis.stage"], equals: "Saving cast suggestions", seconds: 65)
        XCTAssertEqual(app.staticTexts["manage.analysis.count"].label, "4 of 4 passages analyzed")
        XCTAssertNotEqual(app.staticTexts["manage.analysis.stage"].label, "Analysis complete", "Processing every passage is not a committed result")
        shot(app, "Manage audiobook — saving suggestions remains unfinished")
        waitText(app.staticTexts["manage.analysis.stage"], equals: "Analysis complete", seconds: 30)
        waitText(app.staticTexts["manage.analysis.percent"], equals: "100%", seconds: 10)
        checkFirstChapterSetup(app)
        reveal(app.buttons["manage.chapter"], app: app, seekEarlier: true)
        shot(app, "Manage audiobook — completed analysis with actual missing voice and review")
        // Links must open the actual scoped editors, not a decorative count.
        let voices = app.buttons["manage.characters"]; reveal(voices, app: app); voices.tap()
        let create = app.buttons["cast.voice.create.mira"]; reveal(create, app: app)
        XCTAssertTrue(create.exists && create.isHittable)
        closeCast(app)
        let review = app.buttons["manage.review"]; reveal(review, app: app); review.tap()
        let exact = app.staticTexts["cast.review.exact"]
        XCTAssertTrue(exact.waitForExistence(timeout: 15)); XCTAssertTrue(exact.label.contains("Can you hear me?"))
        let reviewCancel = app.buttons["cast.review.cancel"]
        reviewCancel.tap()
        waitForManage(afterClosing: reviewCancel, app: app)
        selectChapter("Across the Bridge", app: app)
        XCTAssertFalse(app.staticTexts["manage.analysis.stage"].exists, "The other chapter cannot inherit the first chapter's job")
        reveal(app.buttons["manage.characters"], app: app)
        XCTAssertEqual(app.buttons["manage.characters"].value as? String, "Voices ready")
        XCTAssertEqual(app.buttons["manage.review"].value as? String, "No lines to check")
        reveal(app.buttons["manage.main"], app: app)
        XCTAssertEqual(app.buttons["manage.main"].label, "Generate audio")
        shot(app, "Manage audiobook — reviewed second chapter ready without leaked first chapter state")
        app.buttons["manage.main"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "manage.generate.chapter").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["manage.generate.page"].exists, "A first-chapter page snapshot cannot be used for a different selected chapter")
        app.buttons.matching(identifier: "manage.generate.chapter").firstMatch.tap()
        waitQueued(app)
        // Return to the blocked chapter: single narrator remains usable without
        // assigning Mira's missing cast voice or silently reviewing her lines.
        selectChapter("The Lantern", app: app)
        // Selecting a chapter can leave the compact screen scrolled below its
        // narration picker. Reveal the real button before sending the tap.
        let kyon = app.buttons["manage.narration.kyon"]
        reveal(kyon, app: app, seekEarlier: true, requireFullVisibility: true); assertTouchTarget(kyon)
        XCTAssertTrue(kyon.isEnabled)
        shot(app, "Manage audiobook — visible Kyon control before changing narration")
        kyon.tap()
        let switched = [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["manage.analysis.start"]),
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["manage.characters"]),
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Generate audio"), object: app.buttons["manage.main"])
        ]
        let switchResult = XCTWaiter.wait(for: switched, timeout: 10)
        let companionError = app.staticTexts["manage.error"]
        XCTAssertEqual(switchResult, .completed, "Kyon must remove cast blockers; companion error: \(companionError.exists ? companionError.label : "none")")
        XCTAssertFalse(app.buttons["manage.analysis.start"].exists)
        XCTAssertFalse(app.buttons["manage.characters"].exists)
        reveal(app.buttons["manage.main"], app: app); XCTAssertEqual(app.buttons["manage.main"].label, "Generate audio")
        app.buttons["manage.main"].tap()
        submitAvailableScope(app)
        waitQueued(app)
        shot(app, "Manage audiobook — Kyon request queued despite unresolved full cast setup")
    }

    func testManageAudiobookLostAnalysisResponseRecoversWithoutDuplicateSubmission() {
        executionTimeAllowance = 300
        let app = makeApp(extra: ["--manage-analysis-lost-response"]); app.launch(); openManage(app); chooseCast(app)
        let start = app.buttons["manage.analysis.start"]; reveal(start, app: app); start.tap()
        acceptGoogleAnalysis(app)
        let resume = app.buttons["manage.analysis.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "A lost acknowledgement must retain an actionable uncertain request")
        reveal(resume, app: app); XCTAssertTrue(resume.isHittable)
        XCTAssertFalse(app.buttons["reader.player.generate"].exists)
        shot(app, "Manage audiobook — lost acknowledgement keeps recoverable accepted request")
        resume.tap()
        XCTAssertFalse(app.alerts["Analyze with Google?"].exists, "Resuming must preserve the accepted request's original consent")
        waitText(app.staticTexts["manage.analysis.count"], equals: "2 of 4 passages analyzed", seconds: 35)
        shot(app, "Manage audiobook — same accepted analysis recovered after lost response")
        app.buttons["manage.close"].tap()
        XCTAssertTrue(app.buttons["reader.speak"].waitForExistence(timeout: 10))
        app.terminate(); app.launch(); openManage(app); chooseCast(app)
        XCTAssertTrue(app.staticTexts["manage.analysis.stage"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["Analyze with Google?"].exists)
        waitText(app.staticTexts["manage.analysis.stage"], equals: "Analysis complete", seconds: 80)
        checkFirstChapterSetup(app)
        XCTAssertFalse(app.staticTexts["manage.generation.status"].exists)
        reveal(app.buttons["manage.chapter"], app: app, seekEarlier: true)
        shot(app, "Manage audiobook — restart recovers server job without duplicate analysis or generation")
    }

    private func makeApp(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--manage-audiobook-fixture", "--manage-persistence-id=" + UUID().uuidString] + extra
        return app
    }
    private func acceptGoogleAnalysis(_ app: XCUIApplication) {
        let alert = app.alerts["Analyze with Google?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        // iOS exposes the alert action and its labelled child with the same
        // identifier. Scope to this real consent alert and its first action.
        let accept = alert.buttons.matching(identifier: "manage.analysis.consent.accept").firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10)); XCTAssertTrue(accept.isEnabled && accept.isHittable)
        accept.tap()
    }
    private func openManage(_ app: XCUIApplication) {
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30)); XCTAssertTrue(book.label.contains("Manage transport fixture")); book.tap()
        let speak = app.buttons["reader.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: speak)], timeout: 20), .completed)
        openManageFromReader(app)
    }
    private func openManageFromReader(_ app: XCUIApplication) {
        app.buttons["reader.options"].tap()
        let manage = app.buttons["reader.manageAudiobook"]; XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        XCTAssertTrue(app.buttons["manage.close"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Manage audiobook"].exists)
        XCTAssertTrue(app.buttons["manage.chapter"].waitForExistence(timeout: 15))
    }
    private func chooseCast(_ app: XCUIApplication) {
        let cast = app.buttons["manage.narration.cast"]; reveal(cast, app: app); assertTouchTarget(cast); cast.tap()
        XCTAssertTrue(app.buttons["manage.characters"].waitForExistence(timeout: 20))
    }
    private func checkFirstChapterSetup(_ app: XCUIApplication) {
        let voices = app.buttons["manage.characters"]; reveal(voices, app: app)
        XCTAssertEqual(voices.value as? String, "1 need voices")
        let review = app.buttons["manage.review"]; reveal(review, app: app)
        XCTAssertEqual(review.value as? String, "1 lines to check")
        let main = app.buttons["manage.main"]; reveal(main, app: app)
        XCTAssertEqual(main.label, "Choose character voices")
        XCTAssertFalse(app.buttons["reader.player.generate"].exists)
    }
    private func selectChapter(_ title: String, app: XCUIApplication) {
        let picker = app.buttons["manage.chapter"]
        reveal(picker, app: app, seekEarlier: true, requireFullVisibility: true)
        assertTouchTarget(picker); XCTAssertTrue(picker.isEnabled)
        picker.tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), "The native chapter menu must expose the exact selected book chapter")
        // Native menu actions can briefly report nonhittable even when their
        // actual tap selects the correct chapter. Verify the real result below.
        XCTAssertTrue(chapter.isEnabled)
        chapter.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", title), object: picker)], timeout: 10), .completed)
        XCTAssertEqual(picker.value as? String, title)
    }
    private func closeCast(_ app: XCUIApplication) {
        let save = app.buttons["cast.save"]
        let close = save.exists ? save : app.buttons["Save & close"]
        XCTAssertTrue(close.isEnabled && close.isHittable); close.tap()
        waitForManage(afterClosing: close, app: app)
    }
    private func waitForManage(afterClosing childControl: XCUIElement, app: XCUIApplication) {
        // Underlying Manage elements remain in the accessibility tree while a
        // child sheet closes. Existence alone cannot prove that it is dismissed.
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: childControl)
        let accessible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: app.buttons["manage.close"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed, accessible], timeout: 15), .completed)
    }
    private func submitAvailableScope(_ app: XCUIApplication) {
        // Manage owns the scope decision; target its native choices when present.
        let chapter = app.buttons.matching(identifier: "manage.generate.chapter").firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10)); chapter.tap()
    }
    private func waitQueued(_ app: XCUIApplication) {
        let status = app.staticTexts["manage.generation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 25))
        waitText(status, contains: "Queued", seconds: 20)
    }
    private func waitText(_ element: XCUIElement, equals value: String, seconds: TimeInterval) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", value), object: element)], timeout: seconds), .completed)
    }
    private func waitText(_ element: XCUIElement, contains value: String, seconds: TimeInterval) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", value), object: element)], timeout: seconds), .completed)
    }
    private func assertTouchTarget(_ element: XCUIElement) {
        XCTAssertTrue(element.exists && element.isHittable)
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.height, 44)
        XCTAssertGreaterThanOrEqual(frame.width, 44)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, seekEarlier: Bool = false, requireFullVisibility: Bool = false) {
        for _ in 0..<8 {
            let containers = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
            let scroll = containers.filter { $0.exists && $0.frame.height > 120 }.max { $0.frame.height < $1.frame.height }
            let frame = scroll?.frame ?? app.frame
            let top = max(frame.minY + 10, app.navigationBars.firstMatch.frame.maxY + 10)
            let bottom = min(frame.maxY - 25, app.frame.maxY - 30)
            let fullyVisible = element.exists && element.frame.minY >= top && element.frame.maxY <= bottom
            if element.exists && element.isHittable && (!requireFullVisibility || fullyVisible) { return }
            let backwards = element.exists && element.frame.height > 0 ? (requireFullVisibility ? element.frame.minY < top : element.frame.maxY <= top) : seekEarlier
            let startY = backwards ? top + (bottom - top) * 0.4 : top + (bottom - top) * 0.75
            let endY = backwards ? top + (bottom - top) * 0.75 : top + (bottom - top) * 0.4
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: frame.midX, dy: startY)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: endY)))
        }
        XCTAssertTrue(element.exists && element.isHittable, "A real native control must be reachable: \(element)")
        if requireFullVisibility {
            XCTAssertGreaterThanOrEqual(element.frame.minY, app.navigationBars.firstMatch.frame.maxY + 10)
            XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY - 30)
        }
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
