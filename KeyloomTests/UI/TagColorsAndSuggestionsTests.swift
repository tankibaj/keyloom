import XCTest
@testable import Keyloom

@MainActor
final class TagColorsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "kl-tag-colors-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    func testAnUnknownTagHasNoColor() {
        XCTAssertNil(TagColors(defaults: defaults()).color(for: "email"))
    }

    func testSetGetAndClear() {
        let colors = TagColors(defaults: defaults())
        colors.set(.teal, for: "email")
        XCTAssertEqual(colors.color(for: "email"), .teal)
        colors.set(.pink, for: "email")
        XCTAssertEqual(colors.color(for: "email"), .pink, "a new color replaces the old one")
        colors.set(nil, for: "email")
        XCTAssertNil(colors.color(for: "email"))
    }

    func testChoosingTheCurrentColorAgainClearsIt() {
        let colors = TagColors(defaults: defaults())
        colors.set(.red, for: "work")
        colors.set(.red, for: "work")
        XCTAssertNil(colors.color(for: "work"))
    }

    func testTheNameIsNormalized() {
        let colors = TagColors(defaults: defaults())
        colors.set(.green, for: "  Café ")
        XCTAssertEqual(colors.color(for: "cafe\u{301}"), .green, "case, spaces and canonical composition do not matter")
    }

    func testItPersistsAcrossInstances() {
        let store = defaults()
        TagColors(defaults: store).set(.purple, for: "code")
        XCTAssertEqual(TagColors(defaults: store).color(for: "code"), .purple)
        let again = TagColors(defaults: store)
        again.set(nil, for: "code")
        XCTAssertNil(TagColors(defaults: store).color(for: "code"))
        XCTAssertNil(store.data(forKey: TagColors.defaultsKey), "the last color removed leaves no key behind")
    }

    func testCorruptOrUnknownStoredValuesReadAsNoColor() {
        let store = defaults()
        store.set(Data("not json".utf8), forKey: TagColors.defaultsKey)
        XCTAssertNil(TagColors(defaults: store).color(for: "x"))
        store.set(try! JSONEncoder().encode(["x": "chartreuse", "y": "blue"]), forKey: TagColors.defaultsKey)
        let colors = TagColors(defaults: store)
        XCTAssertNil(colors.color(for: "x"))
        XCTAssertEqual(colors.color(for: "y"), .blue)
    }

    func testABlankTagIsIgnored() {
        let store = defaults()
        let colors = TagColors(defaults: store)
        colors.set(.red, for: "   ")
        XCTAssertNil(store.data(forKey: TagColors.defaultsKey))
    }
}

final class TagSuggestionsTests: XCTestCase {
    private let all = ["code", "email", "support", "work"]

    func testNothingTypedOffersEveryTagTheSnippetLacks() {
        XCTAssertEqual(TagSuggestions.suggestions(typed: "", available: all, excluding: ["email"]), ["code", "support", "work"])
    }

    func testItFiltersByCaseInsensitivePrefix() {
        XCTAssertEqual(TagSuggestions.suggestions(typed: "S", available: all, excluding: []), ["support"])
        XCTAssertEqual(TagSuggestions.suggestions(typed: " wo", available: all, excluding: []), ["work"])
        XCTAssertEqual(TagSuggestions.suggestions(typed: "ork", available: all, excluding: []), [], "a prefix, not a substring")
    }

    func testTagsAlreadyOnTheSnippetAreLeftOutWhateverTheCase() {
        XCTAssertEqual(TagSuggestions.suggestions(typed: "e", available: all, excluding: ["Email"]), [])
    }

    func testNoMatchOffersNothingSoTheTypedNameCreatesANewTag() {
        XCTAssertTrue(TagSuggestions.suggestions(typed: "zzz", available: all, excluding: []).isEmpty)
    }

    func testDuplicatesAreCollapsedAndTheListIsCapped() {
        XCTAssertEqual(TagSuggestions.suggestions(typed: "", available: ["a", "A", "b"], excluding: []), ["a", "b"])
        let many = (0..<20).map { "t\($0)" }
        XCTAssertEqual(TagSuggestions.suggestions(typed: "t", available: many, excluding: [], limit: 5).count, 5)
    }
}
