import AppKit
import XCTest
@testable import Keyloom

final class SymbolCatalogTests: XCTestCase {
    func testEveryCatalogSymbolResolvesOnThisSystemAndNoneIsListedTwice() {
        let names = SymbolCatalog.allNames
        for name in names {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) does not resolve")
        }
        XCTAssertEqual(Set(names).count, names.count, "duplicates: \(Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    func testTheCatalogIsCuratedAndCategorized() {
        XCTAssertTrue((300...500).contains(SymbolCatalog.allNames.count), "\(SymbolCatalog.allNames.count) symbols")
        let titles = SymbolCatalog.sections.map(\.title)
        for expected in ["MAPS", "DEVICES", "COMMUNICATION", "OBJECTS", "NATURE", "COMMERCE", "HEALTH", "MATH", "TRANSPORT"] {
            XCTAssertTrue(titles.contains(expected), expected)
        }
        for section in SymbolCatalog.sections {
            XCTAssertEqual(section.title, section.title.uppercased())
            XCTAssertFalse(section.symbols.isEmpty, section.title)
            for entry in section.symbols { XCTAssertFalse(entry.keywords.isEmpty, "\(entry.name) needs a search keyword") }
        }
    }

    func testTheSymbolsTheOldPickerOfferedAreStillAvailable() {
        for name in ["text.bubble", "envelope", "calendar", "clock", "star", "bolt", "link", "phone", "house", "briefcase", "doc.text",
                     "signature", "person", "tag", "bookmark", "lightbulb", "checkmark.seal", "globe", "key", "creditcard"] {
            XCTAssertTrue(SymbolCatalog.allNames.contains(name), name)
        }
    }

    func testSearchMatchesNamesAndKeywordsIgnoringCaseAndHidesEmptySections() {
        let byKeyword = SymbolCatalog.sections(matching: "MAIL").flatMap(\.symbols).map(\.name)
        XCTAssertTrue(byKeyword.contains("envelope"), "mail finds envelope through its keyword")
        let byName = SymbolCatalog.sections(matching: "  Envel ").flatMap(\.symbols).map(\.name)
        XCTAssertTrue(byName.contains("envelope"))
        let hits = SymbolCatalog.sections(matching: "mail")
        XCTAssertTrue(hits.allSatisfy { !$0.symbols.isEmpty }, "sections with no match are hidden")
        XCTAssertLessThan(hits.count, SymbolCatalog.sections.count)
        XCTAssertEqual(SymbolCatalog.sections(matching: "").map(\.title), SymbolCatalog.sections.map(\.title))
        XCTAssertEqual(SymbolCatalog.sections(matching: "   "), SymbolCatalog.sections)
    }

    func testEverySearchTermMustMatchAndNonsenseMatchesNothing() {
        let narrowed = SymbolCatalog.sections(matching: "mail open").flatMap(\.symbols).map(\.name)
        let broad = SymbolCatalog.sections(matching: "mail").flatMap(\.symbols).map(\.name)
        XCTAssertLessThan(narrowed.count, broad.count)
        XCTAssertTrue(SymbolCatalog.sections(matching: "zzqxv").isEmpty)
    }

    func testTheLabelIsTheHumanizedName() {
        XCTAssertEqual(SymbolEntry(name: "person.crop.circle.fill", keywords: ["x"]).label, "person crop circle fill")
        XCTAssertEqual(SnippetIcon.symbol("text.bubble", color: .blue).spoken, "text bubble, blue")
        XCTAssertEqual(SnippetIcon.symbol("text.bubble").spoken, "text bubble")
        XCTAssertEqual(SnippetIcon.emoji("👋").spoken, "👋")
    }
}

final class IconColorPaletteTests: XCTestCase {
    private func rgb(_ color: IconColor, _ appearance: NSAppearance.Name) -> [Int] {
        var result: [Int] = []
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = color.nsColor.usingColorSpace(.sRGB)!
            result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        return result
    }

    func testEveryColorIsNamedAndDistinctInLightAndDark() {
        XCTAssertEqual(IconColor.allCases.count, 15)
        XCTAssertEqual(Set(IconColor.allCases.map(\.displayName)).count, 15)
        XCTAssertEqual(IconColor.salmon.displayName, "Salmon")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let values = IconColor.allCases.map { rgb($0, appearance) }
            XCTAssertEqual(Set(values.map { $0.map(String.init).joined(separator: ",") }).count, 15, "\(appearance.rawValue): two colors look the same")
        }
    }

    func testColorsAdaptToTheAppearanceInsteadOfFreezingAnRGBValue() {
        for color in [IconColor.red, .blue, .salmon, .sage] {
            XCTAssertNotEqual(rgb(color, .aqua), rgb(color, .darkAqua), "\(color) must come from adaptive system colors")
        }
    }

    func testSystemColorsMapDirectly() {
        var matches = false
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            matches = IconColor.red.nsColor.usingColorSpace(.sRGB) == NSColor.systemRed.usingColorSpace(.sRGB)
                && IconColor.blue.nsColor.usingColorSpace(.sRGB) == NSColor.systemBlue.usingColorSpace(.sRGB)
        }
        XCTAssertTrue(matches)
    }
}

final class IconPickerModelTests: XCTestCase {
    func testItOpensOnTheKindOfTheCurrentIcon() {
        XCTAssertEqual(IconPickerModel(icon: .emoji("👋")).mode, .emoji)
        XCTAssertEqual(IconPickerModel(icon: .symbol("star")).mode, .symbols)
        let model = IconPickerModel(icon: .symbol("star", color: .teal))
        XCTAssertEqual(model.selectedSymbol, "star")
        XCTAssertEqual(model.selectedColor, .teal)
        XCTAssertNil(IconPickerModel(icon: .emoji("👋")).selectedSymbol)
    }

    func testFilteringHidesEmptySectionsAndReportsNoMatches() {
        var model = IconPickerModel(icon: .symbol("star"))
        XCTAssertEqual(model.visibleSections.map(\.title), SymbolCatalog.sections.map(\.title))
        XCTAssertFalse(model.hasNoMatches)
        model.query = "mail"
        XCTAssertFalse(model.visibleSections.isEmpty)
        XCTAssertTrue(model.visibleSections.flatMap(\.symbols).contains { $0.name == "envelope" })
        model.query = "zzqxv"
        XCTAssertTrue(model.visibleSections.isEmpty)
        XCTAssertTrue(model.hasNoMatches)
    }

    func testChoosingASymbolKeepsTheCurrentColor() {
        var model = IconPickerModel(icon: .symbol("star", color: .blue))
        model.select(symbol: "bolt")
        XCTAssertEqual(model.icon, .symbol("bolt", color: .blue))
        XCTAssertEqual(model.selectedSymbol, "bolt")
    }

    func testChoosingAColorRecolorsTheSymbolAndChoosingItAgainClearsIt() {
        var model = IconPickerModel(icon: .symbol("star"))
        model.select(color: .red)
        XCTAssertEqual(model.icon, .symbol("star", color: .red), "a color-only change")
        model.select(color: .green)
        XCTAssertEqual(model.icon, .symbol("star", color: .green))
        model.select(color: .green)
        XCTAssertEqual(model.icon, .symbol("star", color: nil), "the selected swatch deselects, back to the default tint")
    }

    func testEmojiIgnoresColorAndTheColorComesBackWithTheNextSymbol() {
        var model = IconPickerModel(icon: .symbol("star", color: .indigo))
        model.select(emoji: "🚀")
        XCTAssertEqual(model.icon, .emoji("🚀"))
        model.mode = .symbols
        XCTAssertNil(model.selectedSymbol)
        XCTAssertEqual(model.selectedColor, .indigo, "the color stays chosen while an emoji is the icon")
        model.select(color: .pink)
        XCTAssertEqual(model.icon, .emoji("🚀"), "choosing a color never turns an emoji into a symbol")
        model.select(symbol: "heart")
        XCTAssertEqual(model.icon, .symbol("heart", color: .pink))
    }

    func testTypedEmojiIsAppliedOnlyWhenItIsOne() {
        var model = IconPickerModel(icon: .symbol("star"))
        XCTAssertFalse(model.applyTyped("hello"))
        XCTAssertEqual(model.icon, .symbol("star"))
        XCTAssertTrue(model.applyTyped(" 🎉 "))
        XCTAssertEqual(model.icon, .emoji("🎉"))
    }

    // MARK: Arrow keys

    private func sections(_ counts: Int...) -> [SymbolSection] {
        counts.enumerated().map { index, count in
            SymbolSection(title: "S\(index)", symbols: (0..<count).map { SymbolEntry(name: "s\(index).\($0)", keywords: ["k"]) })
        }
    }

    func testLeftAndRightWalkTheGridInReadingOrderAcrossSections() {
        let grid = sections(10, 3)
        func move(_ name: String, _ direction: IconPickerModel.Direction) -> String? {
            IconPickerModel.neighbor(of: name, direction, in: grid)
        }
        XCTAssertEqual(move("s0.0", .right), "s0.1")
        XCTAssertEqual(move("s0.7", .right), "s0.8", "wraps to the next row")
        XCTAssertEqual(move("s0.9", .right), "s1.0", "and into the next section")
        XCTAssertEqual(move("s1.0", .left), "s0.9")
        XCTAssertNil(move("s0.0", .left))
        XCTAssertNil(move("s1.2", .right))
    }

    func testUpAndDownKeepTheColumnAndClampToShortRows() {
        let grid = sections(10, 3)
        func move(_ name: String, _ direction: IconPickerModel.Direction) -> String? {
            IconPickerModel.neighbor(of: name, direction, in: grid)
        }
        XCTAssertEqual(move("s0.1", .down), "s0.9", "second row of the section")
        XCTAssertEqual(move("s0.3", .down), "s0.9", "the short last row clamps to its last item")
        XCTAssertEqual(move("s0.9", .down), "s1.1", "the next section's first row, same column")
        XCTAssertEqual(move("s0.6", .down), "s0.9", "clamped, as the second row has two items")
        XCTAssertEqual(move("s1.0", .up), "s0.8", "last row of the previous section, same column")
        XCTAssertEqual(move("s1.2", .up), "s0.9", "clamped to that row's last item")
        XCTAssertEqual(move("s0.9", .up), "s0.1")
        XCTAssertNil(move("s0.4", .up))
        XCTAssertNil(move("s1.1", .down))
        XCTAssertNil(move("missing", .down))
    }
}
