import XCTest
import UIKit

final class ReaderUITests: XCTestCase {
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
        XCTAssertTrue(app.buttons["reader.player.narrator"].waitForExistence(timeout: 10))
        chooseReaderNarrator(app, "kyon")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled, "Unrelated transport audio must not become Kyon")
        assertReaderPlayerFits(app, name: "Obsidian reader player largest text portrait")
        assertReaderScopeChoicesFit(app, name: "Obsidian generation choices largest text portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForScreenshotOrientation(landscape: true))
        assertReaderPlayerFits(app, name: "Obsidian reader player largest text landscape")
        assertReaderScopeChoicesFit(app, name: "Obsidian generation choices largest text landscape")
    }

    private func chooseReaderNarrator(_ app: XCUIApplication, _ mode: String) {
        let menu = app.buttons["reader.player.narrator"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: menu)], timeout: 20), .completed)
        menu.tap()
        let choice = app.buttons["reader.voice." + mode]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); assertMinimumHitArea(choice); choice.tap()
        if mode != "device" {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["reader.player.generate"])], timeout: 20), .completed)
        }
    }

    private func assertReaderPlayerFits(_ app: XCUIApplication, name: String) {
        let surface = app.otherElements["reader.player.surface"]
        XCTAssertTrue(surface.exists)
        XCTAssertEqual(surface.scrollViews.count, 0, "The compact reader player must not scroll")
        var frames: [String] = []
        for id in ["narrator", "backward", "toggle", "forward", "speed", "chapters", "sleep", "generate", "details"] {
            let control = app.buttons["reader.player." + id]
            if control.isEnabled { assertMinimumHitArea(control) }
            else {
                XCTAssertTrue(control.exists && app.frame.contains(control.frame))
                XCTAssertGreaterThanOrEqual(control.frame.width + 0.001, 44)
                XCTAssertGreaterThanOrEqual(control.frame.height + 0.001, 44)
            }
            frames.append("\(id): \(control.frame)")
        }
        XCTAssertLessThanOrEqual(app.buttons["reader.player.backward"].frame.maxX, app.buttons["reader.player.toggle"].frame.minX)
        XCTAssertLessThanOrEqual(app.buttons["reader.player.toggle"].frame.maxX, app.buttons["reader.player.forward"].frame.minX)
        XCTAssertFalse(app.buttons["reader.player.toggle"].frame.intersects(app.buttons["reader.player.generate"].frame), "Transport and actions must not overlap in either layout")
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
        assertReaderPlayerFits(app, name: "Obsidian reader with matching offline take")
        play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 10), .completed)
        play.tap(); XCTAssertEqual(play.value as? String, "Paused")
        let slider = app.sliders["reader.player.seek"]
        XCTAssertTrue(slider.exists && slider.isHittable); slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertGreaterThan(slider.normalizedSliderPosition, 0.3); XCTAssertLessThan(slider.normalizedSliderPosition, 0.7)
        app.buttons["reader.player.speed"].tap(); app.buttons["1.5×"].tap()
        app.navigationBars["Read aloud"].buttons["Done"].tap()
        app.buttons["reader.close"].tap(); app.tabBars.buttons["Listen"].tap()
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 90, "The actual local fixture recording must be loaded")
        XCTAssertEqual(app.buttons["listen.speed"].value as? String, "1.5×")
        app.tabBars.buttons["Library"].tap(); book.tap(); XCTAssertTrue(waitForReaderContents(app))
        app.buttons["reader.contents"].tap(); app.buttons["Across the Bridge"].tap()
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
        XCTAssertEqual(audioSeconds(app.staticTexts["listen.duration"]), 120)
    }

    private func startReaderSpeech(_ app: XCUIApplication) {
        app.buttons["reader.speak"].tap()
        let play = app.buttons["reader.player.toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(play.value as? String, "Paused", "Opening Read aloud must not start speech")
        XCTAssertTrue(app.buttons["reader.player.narrator"].label.contains("On-device"))
        XCTAssertTrue(play.isEnabled); play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: play)], timeout: 20), .completed, "Actual on-device speech must start")
        XCTAssertEqual(app.buttons["reader.player.backward"].label, "Previous passage")
        app.navigationBars["Read aloud"].buttons["Done"].tap()
    }

    private func assertMinimumHitArea(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists && element.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width + 0.001, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 0.001, 44, file: file, line: line)
        XCTAssertTrue(XCUIApplication().frame.contains(element.frame), file: file, line: line)
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
        XCTAssertTrue(waitForReaderContents(app))
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        // Cold WebKit exposes the toolbar before revealing its initial spread.
        // Do not open another presentation until the original page is painted.
        guard assertVisibleInk(in: paragraph) else { return }
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["The Lantern"].waitForExistence(timeout: 10)); app.buttons["The Lantern"].tap()
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30))
        guard assertVisibleInk(in: paragraph) else { return }
        app.buttons["reader.speak"].tap()
        XCTAssertTrue(app.buttons["reader.player.narrator"].waitForExistence(timeout: 10))
        chooseReaderNarrator(app, "kyon")
        XCTAssertFalse(app.buttons["reader.player.toggle"].isEnabled)
        app.buttons["reader.player.generate"].tap()
        let page = app.buttons["reader.generate.page"]
        XCTAssertTrue(app.buttons["reader.generate.chapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        assertMinimumHitArea(page); assertMinimumHitArea(app.buttons["reader.generate.chapter"])
        page.tap()
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
        for name in ["Library", "Listen", "Studio"] {
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
