import AppKit
import SwiftUI
import XCTest
@testable import Keyloom

final class PlaceholderSourceTests: XCTestCase {
    func testSimplePlaceholdersParseBackToTheirKind() throws {
        let cases: [(Placeholder, TokenKind)] = [
            (.date(format: nil), .date(format: nil)),
            (.date(format: "yyyy-MM-dd"), .date(format: "yyyy-MM-dd")),
            (.time(format: "HH:mm"), .time(format: "HH:mm")),
            (.uuid, .uuid), (.clipboard, .clipboard), (.cursor, .cursor),
        ]
        for (placeholder, kind) in cases {
            let source = try placeholder.source()
            guard case .token(let token)? = try TokenParser.parse(source).spans.first?.span else { return XCTFail(source) }
            XCTAssertEqual(token.kind, kind, source)
            XCTAssertEqual(token.raw, source)
        }
    }

    func testArgumentWithNameDefaultAndChoices() throws {
        let source = try Placeholder.argument(name: "recipient", defaultValue: "Team", choices: ["Team", "Ann"]).source()
        XCTAssertEqual(source, "{argument name=\"recipient\" default=\"Team\" options=\"Team, Ann\"}")
        guard case .token(let token)? = try TokenParser.parse(source).spans.first?.span else { return XCTFail() }
        XCTAssertEqual(token.kind, .argument(name: "recipient", defaultValue: "Team", choices: ["Team", "Ann"]))
    }

    func testArgumentEscapesQuotesAndBackslashes() throws {
        let source = try Placeholder.argument(name: "q\"x", defaultValue: "a\\b", choices: []).source()
        guard case .token(let token)? = try TokenParser.parse(source).spans.first?.span else { return XCTFail() }
        XCTAssertEqual(token.kind, .argument(name: "q\"x", defaultValue: "a\\b", choices: []))
    }

    func testInvalidArgumentsAreRejectedWithAMessage() {
        XCTAssertThrowsError(try Placeholder.argument(name: "  ", defaultValue: nil, choices: []).source())
        XCTAssertThrowsError(try Placeholder.argument(name: "x", defaultValue: "c", choices: ["a", "b"]).source(), "default must be a choice")
        XCTAssertThrowsError(try Placeholder.argument(name: "x", defaultValue: nil, choices: ["a,b"]).source(), "commas separate choices")
    }

    func testFormFieldsBuildAPlaceholderAndEmptyOptionalsAreOmitted() throws {
        var form = ArgumentForm()
        XCTAssertNil(form.placeholder, "a name is required")
        form.name = " recipient "
        form.choicesText = "Team, Ann ,, "
        XCTAssertEqual(try form.placeholder?.source(), "{argument name=\"recipient\" options=\"Team, Ann\"}")
        form.defaultValue = "Ann"
        XCTAssertEqual(try form.placeholder?.source(), "{argument name=\"recipient\" default=\"Ann\" options=\"Team, Ann\"}")
    }
}

final class IconCatalogTests: XCTestCase {
    func testEverySuggestedSymbolExistsOnThisSystem() {
        XCTAssertFalse(IconCatalog.symbols.isEmpty)
        for name in IconCatalog.symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testEmojiInputAcceptsOneEmojiAndNothingElse() {
        for good in ["😀", "👩‍👩‍👧", "❤️", "1️⃣", "🇩🇪", " 👋 "] { XCTAssertNotNil(IconCatalog.emoji(from: good), good) }
        for bad in ["", "a", "1", "😀😀", "hello", "é"] { XCTAssertNil(IconCatalog.emoji(from: bad), bad) }
        XCTAssertEqual(IconCatalog.emoji(from: " 👋 "), .emoji("👋"))
    }

    func testSymbolInputMustBeARealSymbol() {
        XCTAssertEqual(IconCatalog.symbol(from: " star "), .symbol("star"))
        XCTAssertNil(IconCatalog.symbol(from: "not.a.symbol.name"))
    }
}

final class PreviewTextTests: XCTestCase {
    func testSegmentsKeepStylesAndTheCursorShowsAsAMarker() {
        let rendered = RenderedSnippet(segments: [StyledSegment(text: "Hi ", style: []), StyledSegment(text: "Ann", style: [.bold, .underline])],
                                       plainText: "Hi Ann", cursorOffset: 5)
        let text = PreviewText.attributed(rendered)
        XCTAssertEqual(String(text.characters), "Hi An\(PreviewText.cursorMarker)n")
        let bold = text.runs.first { String(text[$0.range].characters) == "An" }
        XCTAssertNotNil(bold?.underlineStyle)
    }

    func testNoCursorMeansNoMarker() {
        let rendered = RenderedSnippet(segments: [StyledSegment(text: "x", style: [])], plainText: "x", cursorOffset: nil)
        XCTAssertEqual(String(PreviewText.attributed(rendered).characters), "x")
    }
}
