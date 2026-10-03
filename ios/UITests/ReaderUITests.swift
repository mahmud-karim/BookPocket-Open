import XCTest
import UIKit

final class ReaderUITests: XCTestCase {
    func testNarrationMiniPlayerLeavesNativeTabsVisibleAndUsable() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        // Use a real installed Apple voice at the slowest speed exposed in the app.
        app.launchArguments = ["--uitesting", "--import-fixture", "-playbackRate", "0.75"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 30))
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 10))
        app.buttons["The Lantern"].tap()
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mira opened the brass lantern")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30))
        assertVisibleInk(in: paragraph)
        let speak = app.buttons["reader.speak"]
        speak.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: speak)], timeout: 20), .completed, "Actual on-device speech must start")
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
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 30))
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
    private func assertVisibleInk(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
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
        XCTAssertEqual(result, .completed, "EPUB text must be visibly painted, not only present in accessibility", file: file, line: line)
    }
}
