import XCTest
import UIKit

final class ReadAloudPlayerUITests: XCTestCase {
    private func app(_ fixture: String = "--reader-continuous-fixture", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--offline-transport-fixture", "--reader-player-fixture", fixture, "-playbackRate", "0.5", "-readerTheme", "cream"] + extra
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["listen.downloads"].waitForExistence(timeout: 45))
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        let speak = app.buttons["reader.speak"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: speak)], timeout: 90), .completed)
        speak.tap()
        source(app, "kyon")
        return app
    }
    private func source(_ app: XCUIApplication, _ mode: String) {
        let narrator = app.buttons["reader.player.narrator"]
        XCTAssertTrue(narrator.waitForExistence(timeout: 10)); narrator.tap()
        let choice = app.buttons["reader.voice." + mode]
        XCTAssertTrue(choice.waitForExistence(timeout: 10)); choice.tap()
        XCTAssertTrue(app.buttons["reader.player.toggle"].waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: narrator)], timeout: 20), .completed)
    }
    private func chooseRecording(_ app: XCUIApplication, _ id: String) {
        app.buttons["reader.player.saved"].tap()
        let recording = app.buttons["reader.saved." + id]
        XCTAssertTrue(recording.waitForExistence(timeout: 15)); recording.tap()
        XCTAssertTrue(app.buttons["reader.player.toggle"].waitForExistence(timeout: 10))
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func paperMatches(_ name: String, app: XCUIApplication) -> Bool {
        // Sample blank status-safe-area and actual EPUB pixels, rather than
        // trusting a selected segment or the native toolbar's preference.
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let expected = name == "Obsidian" ? [0, 0, 0] : name == "White" ? [255, 255, 255] : [250, 244, 232]
        // On the 667-point SE, the player's top shadow reaches screen 20%.
        // Sample blank EPUB space immediately below the real toolbar instead.
        let pageY = (app.buttons["reader.contents"].frame.maxY + 8) / app.frame.height
        for y in [0.02, Double(pageY)] {
            guard let pixel = image.cropping(to: CGRect(x: Double(image.width) * 0.8, y: Double(image.height) * y, width: 1, height: 1)),
                  let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
            if (0..<3).contains(where: { abs(Int(bytes[$0]) - expected[$0]) > 3 }) { return false }
        }
        return true
    }
    private func waitForPaper(_ name: String, app: XCUIApplication) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.paperMatches(name, app: app) }, object: nil)], timeout: 15), .completed, "The actual EPUB page and reader status area must both use the chosen paper palette")
    }
    private func seconds(_ element: XCUIElement) -> Double {
        // Listen describes the time through its accessibility value; reader
        // timeline labels expose the same clock directly as visible text.
        let value = element.value as? String
        let clock = value?.contains(":") == true ? value! : element.label
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }
    private func waitForClock(_ element: XCUIElement, seconds expected: Double, accuracy: Double = 1) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && abs(self.seconds(element) - expected) <= accuracy
        }, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, "Requested continuous position \(expected); actual clock \(seconds(element))")
    }
    private func seek(_ app: XCUIApplication, normalized target: Double, duration: Double) {
        let slider = app.sliders["reader.player.seek"]
        var gesture = target
        // Apple's native adjustment is best effort. iOS 26's drag landed at
        // 105.67/124 for an 80% request, stably; exact 15-second skips passed.
        // Correct the physical gesture using the real observed slider value.
        // The final clock assertion remains strict at 99.2 seconds, not 106.
        for _ in 0..<4 {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: slider)], timeout: 20), .completed)
            slider.adjust(toNormalizedSliderPosition: CGFloat(gesture))
            let clock = seconds(app.staticTexts["reader.player.elapsed"])
            if abs(clock - duration * target) <= 1 { return }
            let measured = Double(slider.value as? String ?? "") ?? clock
            guard measured.isFinite, measured >= 0, measured <= duration else { return }
            gesture = max(0, min(1, gesture + target - measured / duration))
        }
    }
    private func fits(_ app: XCUIApplication, missing: Bool = false) {
        let surface = app.otherElements["reader.player.surface"]
        XCTAssertTrue(surface.exists)
        XCTAssertGreaterThanOrEqual(surface.frame.maxY, app.frame.maxY - 1, "The charcoal panel includes the home indicator area")
        for id in ["chapters", "narrator", "backward", "toggle", "forward", "speed", "sleep", "close", missing ? "setup" : "manage"] {
            let element = app.buttons["reader.player." + id]
            XCTAssertTrue(element.exists, id)
            XCTAssertTrue(app.frame.contains(element.frame), "\(id) must fit in the real window")
            XCTAssertGreaterThanOrEqual(element.frame.width + 0.1, 44, id)
            XCTAssertGreaterThanOrEqual(element.frame.height + 0.1, 44, id)
            if element.isEnabled { XCTAssertTrue(element.isHittable, id) }
        }
        // A full-screen reader can retain the underlying TabView in the AX tree
        // even though the inspected screen covers it. No tab may be actionable.
        let backgroundTabs = app.tabBars.firstMatch
        if backgroundTabs.exists {
            XCTAssertFalse(backgroundTabs.isHittable, "Immersive reader must cover the application tab bar")
            for name in ["Library", "Listen", "Studio", "Connection"] {
                let tab = backgroundTabs.buttons[name]
                if tab.exists { XCTAssertFalse(tab.isHittable, "A covered application tab must not receive reader touches") }
            }
        }
        XCTAssertFalse(app.buttons["reader.player.generate"].exists)
        XCTAssertFalse(app.buttons["reader.player.pronunciation"].exists)
        XCTAssertFalse(app.buttons["reader.player.cast"].exists)
    }
    func testReadyPageAndChapterUseContinuousTimelineAndShareListenProgress() {
        executionTimeAllowance = 300
        let app = app()
        chooseRecording(app, "reader-continuous-page")
        let toggle = app.buttons["reader.player.toggle"]
        XCTAssertTrue(toggle.isEnabled); XCTAssertEqual(toggle.value as? String, "Paused")
        XCTAssertEqual(seconds(app.staticTexts["reader.player.duration"]), 124)
        fits(app); screenshot("Read aloud ready page — paper top and charcoal bottom")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)], timeout: 10), .completed)
        fits(app); screenshot("Read aloud ready page compact landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)], timeout: 10), .completed)
        seek(app, normalized: 0.8, duration: 124)
        waitForClock(app.staticTexts["reader.player.elapsed"], seconds: 124 * 0.8, accuracy: 2)
        screenshot("Read aloud paused seek to 80 percent across assets")
        let sought = seconds(app.staticTexts["reader.player.elapsed"])
        XCTAssertGreaterThan(sought, 64, "Seeking before Play crosses backend assets without starting narration")
        XCTAssertEqual(toggle.value as? String, "Paused")
        app.buttons["reader.player.backward"].tap()
        waitForClock(app.staticTexts["reader.player.elapsed"], seconds: sought - 15)
        XCTAssertEqual(seconds(app.staticTexts["reader.player.elapsed"]), sought - 15, accuracy: 1)
        app.buttons["reader.player.forward"].tap()
        waitForClock(app.staticTexts["reader.player.elapsed"], seconds: sought)
        XCTAssertEqual(seconds(app.staticTexts["reader.player.elapsed"]), sought, accuracy: 1)
        app.sliders["reader.player.seek"].adjust(toNormalizedSliderPosition: 0)
        waitForClock(app.staticTexts["reader.player.elapsed"], seconds: 0)
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.seconds(app.staticTexts["reader.player.elapsed"]) >= 5 }, object: nil)], timeout: 35), .completed)
        XCTAssertEqual(seconds(app.staticTexts["reader.player.duration"]), 124)
        XCTAssertEqual(toggle.value as? String, "Playing"); toggle.tap()
        screenshot("Read aloud joined timeline after crossing first asset")
        app.buttons["reader.scope.chapter"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)], timeout: 20), .completed)
        XCTAssertEqual(seconds(app.staticTexts["reader.player.duration"]), 184)
        XCTAssertEqual(seconds(app.staticTexts["reader.player.elapsed"]), 0)
        XCTAssertFalse(app.navigationBars["Manage audiobook"].exists, "Scope selection only prepares playback")
        toggle.tap(); toggle.tap(); fits(app); screenshot("Read aloud ready full chapter")
        app.buttons["reader.player.close"].tap()
        XCTAssertFalse(app.buttons["reader.player.toggle"].exists)
        app.buttons["reader.close"].tap(); app.tabBars.buttons["Listen"].tap()
        waitForClock(app.staticTexts["listen.duration"], seconds: 184)
        XCTAssertEqual(seconds(app.staticTexts["listen.duration"]), 184)
        XCTAssertEqual(app.buttons["player.full.toggle"].value as? String, "Paused")
    }
    func testMissingPageAndChapterOpenExplicitExactScopeSetup() {
        executionTimeAllowance = 240
        let app = app("--reader-page-clips-fixture")
        let toggle = app.buttons["reader.player.toggle"]
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertFalse(app.navigationBars["Manage audiobook"].exists)
        fits(app, missing: true); screenshot("Read aloud missing page with explicit setup action")
        XCTAssertEqual(app.buttons["reader.player.setup"].label, "Set up page audio")
        app.buttons["reader.player.setup"].tap()
        XCTAssertTrue(app.navigationBars["Manage audiobook"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["audiobook.setup.context"].label.contains("Current page"))
        let pagePreview = app.staticTexts["reader.generation.preview"]
        XCTAssertTrue(pagePreview.waitForExistence(timeout: 10))
        XCTAssertTrue(pagePreview.label.contains("Mira opened")); XCTAssertFalse(pagePreview.label.contains("Across the Bridge"))
        screenshot("Manage audiobook receives exact page snapshot")
        app.buttons["audiobook.setup.close"].tap()
        app.buttons["reader.scope.chapter"].tap()
        let setup = app.buttons["reader.player.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "No audio for this chapter"), object: app.staticTexts["reader.player.readiness"])], timeout: 20), .completed)
        XCTAssertFalse(app.navigationBars["Manage audiobook"].exists)
        XCTAssertFalse(toggle.isEnabled); XCTAssertFalse(app.sliders["reader.player.seek"].isEnabled)
        screenshot("Read aloud missing chapter with explicit setup action")
        setup.tap(); XCTAssertTrue(app.navigationBars["Manage audiobook"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["audiobook.setup.context"].label.contains("Current chapter"))
        XCTAssertFalse(app.staticTexts["reader.generation.preview"].label.contains("Across the Bridge"))
        app.buttons["audiobook.setup.close"].tap()
        app.buttons["reader.player.chapters"].tap(); app.buttons["reader.player.chapter.1"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Across the Bridge"), object: app.buttons["reader.player.chapters"])], timeout: 20), .completed)
        setup.tap(); XCTAssertTrue(app.navigationBars["Manage audiobook"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Across the Bridge"].exists)
        XCTAssertTrue(app.staticTexts["audiobook.setup.context"].label.contains("Current chapter"))
        screenshot("Manage audiobook receives exact second chapter context")
    }
    func testAlternateRecordingsAndPlaybackSourcesRemainExplicit() {
        executionTimeAllowance = 240
        let app = app("--reader-alternate-takes-fixture")
        let toggle = app.buttons["reader.player.toggle"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Choose a matching recording"), object: app.staticTexts["reader.player.readiness"])], timeout: 20), .completed)
        XCTAssertFalse(toggle.isEnabled)
        chooseRecording(app, "reader-alternate-job")
        XCTAssertTrue(toggle.isEnabled); screenshot("Read aloud explicitly selected alternate recording")
        source(app, "cast")
        XCTAssertFalse(toggle.isEnabled, "Kyon cannot stand in for missing Full cast")
        app.buttons["reader.player.chapters"].tap()
        app.buttons["reader.player.chapter.reader-tone-job-1:reader-chapter-1"].tap()
        XCTAssertTrue(toggle.isEnabled)
        screenshot("Read aloud saved Full cast recording")
        source(app, "device")
        XCTAssertTrue(toggle.isEnabled, "On-device speech requires no generated recording")
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "Playing"); toggle.tap()
        app.buttons["reader.player.speed"].tap(); app.buttons["1.5×"].tap()
        XCTAssertEqual(app.buttons["reader.player.speed"].value as? String, "1.5×")
        app.buttons["reader.player.sleep"].tap(); app.buttons["5 minutes"].tap()
        XCTAssertEqual(app.buttons["reader.player.sleep"].value as? String, "On")
        screenshot("Read aloud on-device playback remains available")
    }
    func testReaderPaperTopAndCloseRespectCreamDarkAndWhiteThemes() {
        executionTimeAllowance = 240
        let app = app()
        chooseRecording(app, "reader-continuous-page")
        waitForPaper("Cream", app: app)
        screenshot("Reader cream top with Read aloud open")
        app.buttons["reader.player.close"].tap(); screenshot("Reader cream top after X close")
        app.buttons["reader.options"].tap(); app.buttons["reader.manageAudiobook"].tap()
        XCTAssertTrue(app.navigationBars["Manage audiobook"].waitForExistence(timeout: 15))
        app.buttons["audiobook.setup.close"].tap()
        for theme in ["Obsidian", "White", "Cream"] {
            app.buttons["reader.options"].tap(); app.buttons["Reading appearance"].tap()
            app.segmentedControls.buttons[theme].tap(); app.buttons["Done"].tap()
            waitForPaper(theme, app: app)
            screenshot("Reader \(theme) top and page after theme change")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["reader.speak"])], timeout: 20), .completed)
            app.buttons["reader.speak"].tap(); waitForPaper(theme, app: app); screenshot("Reader \(theme) top with charcoal Read aloud")
            app.buttons["reader.player.close"].tap()
        }
    }
    func testLargestTextAndLandscapeKeepPlaybackAndSetupReachable() {
        executionTimeAllowance = 240
        let app = app(extra: ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        chooseRecording(app, "reader-continuous-page")
        XCTAssertEqual(seconds(app.staticTexts["reader.player.duration"]), 124)
        screenshot("Read aloud largest text portrait")
        let surface = app.otherElements["reader.player.surface"]
        for id in ["toggle", "speed", "sleep", "manage"] {
            let control = app.buttons["reader.player." + id]
            for _ in 0..<8 { if control.isHittable { break }; surface.swipeUp() }
            XCTAssertTrue(control.isHittable, "\(id) must remain reachable at accessibility sizes")
        }
        app.buttons["reader.player.manage"].tap()
        XCTAssertTrue(app.navigationBars["Manage audiobook"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["audiobook.setup.context"].label.contains("Current page"))
        app.buttons["audiobook.setup.close"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        screenshot("Read aloud largest text landscape")
        app.buttons["reader.player.close"].tap()
        XCTAssertTrue(app.buttons["reader.speak"].waitForExistence(timeout: 10))
    }
}
