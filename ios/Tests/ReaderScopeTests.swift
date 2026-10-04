import XCTest
import WebKit
@testable import BookPocketOpen

final class ReaderScopeTests: XCTestCase {
    private func book(_ chapters: [(String, [String])]) -> RemoteBook {
        RemoteBook(id: "original", title: "Original test story", author: "Test", language: "en", sourceSha256: String(repeating: "a", count: 64), chapters: chapters.enumerated().map { index, chapter in
            RemoteChapter(id: "c\(index)", title: "Chapter \(index)", href: chapter.0, segments: chapter.1.enumerated().map { offset, text in
                RemoteSegment(id: "c\(index)s\(offset)", text: text, kind: "paragraph", locator: .object([:]))
            })
        })
    }
    func testPageKeepsPartialParagraphScalarCoordinatesAndRepeatedTextOrder() throws {
        let text = "A compass 🧭 pointed north; café bells sounded beyond the window."
        let remote = book([("EPUB/a.xhtml", [text, text, "Hidden passage."])])
        let snapshot = ReaderScopeSnapshot(scope: .page, hrefs: ["EPUB/a.xhtml"], documents: ["EPUB/a.xhtml": SourceDocument(blocks: [
            SourceBlock(text: text, visible: [.init(start: 10, end: 30)]),
            SourceBlock(text: text, visible: [.init(start: 0, end: 9)]),
            SourceBlock(text: "Hidden passage.", visible: [])
        ], anchors: [])], current: .init(resource: 0, block: 0, offset: 10), boundaries: [], isText: false)
        let selection = try ReaderSourceMapper.resolve(snapshot, book: remote)
        XCTAssertEqual(selection.ranges, [.init(segmentId: "c0s0", startOffset: 10, endOffset: 30), .init(segmentId: "c0s1", startOffset: 0, endOffset: 9)])
        XCTAssertEqual(selection.excerpts, ["🧭 pointed north; caf", "A compass"])
        var changed = snapshot
        changed.documents["EPUB/a.xhtml"]?.blocks[0].text += " Changed"
        XCTAssertThrowsError(try ReaderSourceMapper.resolve(changed, book: remote))
        var separated = snapshot
        separated.documents["EPUB/a.xhtml"]?.blocks[0].visible = [.init(start: 0, end: 3), .init(start: 10, end: 11)]
        XCTAssertThrowsError(try ReaderSourceMapper.resolve(separated, book: remote), "Hidden interior text must never be silently included")
        var decomposed = snapshot
        decomposed.documents["EPUB/a.xhtml"]?.blocks[0].text = text.replacingOccurrences(of: "é", with: "e\u{301}")
        XCTAssertThrowsError(try ReaderSourceMapper.resolve(decomposed, book: remote), "Canonically equivalent strings have different scalar coordinates")
        let combining = "e\u{301}"
        XCTAssertEqual(String(combining[try XCTUnwrap(SourceIdentity.scalarRange(1, 2, in: combining))]).unicodeScalars.map(\.value), [0x301])
    }
    func testSemanticChapterCrossesImageResourceAndEndsAtInlineFragment() throws {
        let remote = book([("a.xhtml", ["Before Start 🧭 begins."]), ("b.xhtml", ["Continuation. Next chapter."])])
        let first = SourceDocument(blocks: [.init(text: remote.chapters[0].segments[0].text, visible: [])], anchors: [.init(id: "start", block: 0, offset: 7)])
        let last = SourceDocument(blocks: [.init(text: remote.chapters[1].segments[0].text, visible: [])], anchors: [.init(id: "next", block: 0, offset: 14)])
        let start = try ReaderSourceMapper.boundary(fragment: "start", resource: 0, document: first)
        let end = try ReaderSourceMapper.boundary(fragment: "next", resource: 2, document: last)
        let snapshot = ReaderScopeSnapshot(scope: .chapter, hrefs: ["a.xhtml", "plate.svg", "b.xhtml"], documents: ["a.xhtml": first, "plate.svg": .init(blocks: [], anchors: []), "b.xhtml": last], current: .init(resource: 2, block: 0, offset: 0), boundaries: [.init(title: "The journey", point: start), .init(title: "Next", point: end)], isText: false)
        let selection = try ReaderSourceMapper.resolve(snapshot, book: remote)
        XCTAssertEqual(selection.title, "The journey")
        XCTAssertEqual(selection.excerpts, ["Start 🧭 begins.", "Continuation. "])
        XCTAssertEqual(selection.ranges.last?.endOffset, 14)
        var illustration = snapshot
        illustration.current = try ReaderSourceMapper.currentPoint(resource: 1, document: .init(blocks: [], anchors: []), scope: .chapter)
        XCTAssertEqual(try ReaderSourceMapper.resolve(illustration, book: remote).ranges, selection.ranges, "An illustration inside a chapter still selects that semantic chapter")
        XCTAssertThrowsError(try ReaderSourceMapper.currentPoint(resource: 2, document: last, scope: .chapter), "Offscreen text plus an illustration must not silently choose the first of several fragment chapters")
        XCTAssertThrowsError(try ReaderSourceMapper.currentPoint(resource: 1, document: .init(blocks: [], anchors: []), scope: .page))
        var ambiguous = first; ambiguous.anchors.append(first.anchors[0])
        XCTAssertThrowsError(try ReaderSourceMapper.boundary(fragment: "start", resource: 0, document: ambiguous))
        var noTOC = snapshot; noTOC.boundaries = []
        XCTAssertThrowsError(try ReaderSourceMapper.resolve(noTOC, book: remote))
    }
    func testKyonRequiresTheActualAvailableEngineAndUnambiguousVoice() throws {
        let voice = RemoteVoice(id: "public-test-id", name: "Kyon", engine: "voicestudio", kind: "clone", language: "en")
        var engine = RemoteEngine(id: "voicestudio", name: "OmniVoice", available: true, supportsCloning: true, languages: ["en"], license: "Test", reason: nil)
        XCTAssertEqual(try ReaderNarrator.kyon(voices: [voice], engines: [engine]).id, voice.id)
        engine.available = false
        XCTAssertThrowsError(try ReaderNarrator.kyon(voices: [voice], engines: [engine]))
        engine.available = true
        XCTAssertThrowsError(try ReaderNarrator.kyon(voices: [voice, voice], engines: [engine]))
        var other = voice; other.engine = "kokoro"
        XCTAssertThrowsError(try ReaderNarrator.kyon(voices: [other], engines: [engine]))
    }

    func testManagedKyonPreferredWithoutLosingExternalFallback() throws {
        let managed = RemoteVoice(id: "managed", name: "Kyon", engine: "omnivoice", kind: "clone", language: "en")
        let legacy = RemoteVoice(id: "legacy", name: "Kyon", engine: "voicestudio", kind: "clone", language: "en")
        var own = RemoteEngine(id: "omnivoice", name: "OmniVoice", available: true, supportsCloning: true, languages: ["en"], license: "Test", reason: nil)
        let external = RemoteEngine(id: "voicestudio", name: "VoiceStudio", available: true, supportsCloning: false, languages: ["en"], license: "Test", reason: nil)
        XCTAssertEqual(try ReaderNarrator.kyon(voices: [legacy, managed], engines: [external, own]).id, managed.id)
        XCTAssertThrowsError(try ReaderNarrator.kyon(voices: [managed, managed, legacy], engines: [own, external]))
        own.available = false
        XCTAssertEqual(try ReaderNarrator.kyon(voices: [managed, legacy], engines: [own, external]).id, legacy.id)
        XCTAssertThrowsError(try ReaderNarrator.kyon(voices: [managed], engines: [own]))
    }

    @MainActor func testWebKitGlyphCaptureIncludesOnlyVisibleScalarsAfterFontReflow() async throws {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = controller; window.makeKeyAndVisible()
        let web = WKWebView(frame: window.bounds)
        // Match Readium's EPUBSpreadView: this fixed viewport owns its insets.
        // Automatic safe-area adjustment can leave short replacement content
        // scrolled by the device's inset even after JavaScript scrollTo(0, 0).
        web.scrollView.contentInsetAdjustmentBehavior = .never
        controller.view.addSubview(web)
        defer { web.removeFromSuperview(); window.isHidden = true }
        let loaded = expectation(description: "Original synthetic HTML rendered")
        let navigation = ScopeNavigation(loaded); web.navigationDelegate = navigation
        let paragraph = String(repeating: "A compass 🧭 points north; café bells ring. ", count: 18).trimmingCharacters(in: .whitespaces)
        web.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>
        html,body{margin:0;padding:0} body{font:20px/1.5 Georgia} p{margin:0} #hidden{display:none}
        </style></head><body><p>First 🧭 passage.</p><p id="long">\(paragraph)</p><p id="hidden">Hidden source words.</p></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "ReaderScope", withExtension: "js"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        func capture() async throws -> SourceDocument {
            let json = try await web.evaluateJavaScript(script + ";JSON.stringify(bookPocketDocument(document,true))")
            return try JSONDecoder().decode(SourceDocument.self, from: Data(try XCTUnwrap(json as? String).utf8))
        }
        let small = try await capture()
        XCTAssertEqual(small.blocks.count, 3)
        XCTAssertEqual(small.blocks[0].visible, [.init(start: 0, end: "First 🧭 passage.".unicodeScalars.count)])
        let visible = try XCTUnwrap(small.blocks[1].visible.first)
        XCTAssertEqual(visible.start, 0)
        XCTAssertGreaterThan(visible.end, 25)
        XCTAssertLessThan(visible.end, paragraph.unicodeScalars.count, "A partly visible paragraph must not become a whole-paragraph request")
        XCTAssertTrue(small.blocks[2].visible.isEmpty)
        _ = try await web.evaluateJavaScript("document.body.style.fontSize='32px'; document.body.offsetHeight")
        let large = try await capture()
        XCTAssertLessThan(try XCTUnwrap(large.blocks[1].visible.first).end, visible.end)
        XCTAssertEqual(large.blocks.map(\.text), small.blocks.map(\.text), "Reflow changes viewport ranges, never immutable source text")
        _ = try await web.evaluateJavaScript("window.scrollTo(0,150); document.body.offsetHeight")
        let scrolled = try await capture()
        XCTAssertGreaterThan(try XCTUnwrap(scrolled.blocks[1].visible.first).start, 0)
        XCTAssertTrue(scrolled.blocks[0].visible.isEmpty)
        // Hidden interior content creates disjoint visible intervals, which the mapper rejects.
        _ = try await web.evaluateJavaScript("document.body.innerHTML='<p>One<span style=\"display:none\">secret</span>two 🧭</p>';document.body.offsetHeight;window.scrollTo(0,0)")
        // DOM replacement shrinks the scroll range. Wait for WebKit's asynchronous
        // scroll adjustment and layout before measuring the replacement glyphs.
        var stableSamples = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && stableSamples < 2 {
            let settled = try await web.evaluateJavaScript("(() => { const r=document.querySelector('p').getBoundingClientRect(); return Math.abs(scrollY)<0.01 && r.width>0 && r.height>0 && r.top>=0 && r.bottom<=innerHeight; })()") as? Bool == true
            stableSamples = settled ? stableSamples + 1 : 0
            if stableSamples < 2 { try await Task.sleep(for: .milliseconds(100)) }
        }
        if stableSamples < 2 {
            let details = try await web.evaluateJavaScript("JSON.stringify({scrollY,innerHeight,rect:document.querySelector('p').getBoundingClientRect().toJSON()})")
            let attachment = XCTAttachment(string: "\(details)\nNative offset: \(web.scrollView.contentOffset), adjusted inset: \(web.scrollView.adjustedContentInset), bounds: \(web.bounds)")
            attachment.name = "Replacement paragraph layout"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(stableSamples, 2, "Replacement paragraph must settle at the top of the viewport")
        let hidden = try await capture()
        XCTAssertEqual(hidden.blocks[0].text, "Onesecrettwo 🧭")
        XCTAssertEqual(hidden.blocks[0].visible, [.init(start: 0, end: 3), .init(start: 9, end: 14)])
    }
}

@MainActor private final class ScopeNavigation: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
