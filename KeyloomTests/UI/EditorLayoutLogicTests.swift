import AppKit
import XCTest
@testable import Keyloom

@MainActor
final class EditorLayoutLogicTests: XCTestCase {
    func testKeywordSanitizerDropsAllWhitespace() {
        XCTAssertEqual(SnippetDraft.sanitizedKeyword(" ::he llo\t"), "::hello")
        XCTAssertEqual(SnippetDraft.sanitizedKeyword("::ok"), "::ok")
        XCTAssertEqual(SnippetDraft.sanitizedKeyword("  "), "")
    }

    func testUnprovisionedBuildIsUnsupportedForSyncSwitch() {
        XCTAssertTrue(SyncStatusPresentation(.unavailable(.buildNotProvisioned)).isUnsupportedBuild)
        XCTAssertFalse(SyncStatusPresentation(.unavailable(.restricted)).isUnsupportedBuild)
        XCTAssertFalse(SyncStatusPresentation(.off).isUnsupportedBuild)
    }

    /// A click below the last line must land in the text view, so it has to fill the visible area.
    func testBodyTextViewFillsTheScrollViewSoEmptyAreaTakesClicks() {
        let scroll = RichTextView.makeScrollView(controller: RichTextController())
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        scroll.layoutSubtreeIfNeeded()
        scroll.layout()
        let textView = try! XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertGreaterThanOrEqual(textView.frame.height, scroll.contentSize.height)
    }
}

@MainActor
final class TagRenameTests: LibraryUITestCase {
    func testRenameTagUpdatesEverySnippetAndMergesDuplicates() async throws {
        let library = try await openLibrary()
        let doc = Document(paragraphs: [Paragraph(kind: .plain, runs: [Run(style: [], spans: [.literal("t")])])])
        let a = try await library.create(name: "A", icon: .emoji("x"), keyword: nil, tags: ["work", "x"], template: doc)
        let b = try await library.create(name: "B", icon: .emoji("x"), keyword: nil, tags: ["work", "Mail"], template: doc)
        let changed = try await library.renameTag(from: "work", to: "mail")
        XCTAssertEqual(changed, 2)
        let afterA = await library.snippet(id: a.id)
        let afterB = await library.snippet(id: b.id)
        XCTAssertEqual(afterA?.tags, ["mail", "x"])
        XCTAssertEqual(afterB?.tags, ["mail"])
        let none = try await library.renameTag(from: "nope", to: "z")
        XCTAssertEqual(none, 0)
    }

    func testMoveColorCarriesToNewName() {
        let defaults = UserDefaults(suiteName: "tagrename-\(UUID())")!
        let colors = TagColors(defaults: defaults)
        colors.set(.red, for: "work")
        colors.moveColor(from: "work", to: "job")
        XCTAssertNil(colors.color(for: "work"))
        XCTAssertEqual(colors.color(for: "job"), .red)
    }
}
