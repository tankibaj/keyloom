import Foundation

struct KeywordMatch: Equatable {
    /// UTF-16 units the user actually typed for the keyword.
    let keywordLength: Int
    let fixtureIndex: Int
    let hasArgument: Bool
}

struct RenderedSnippet: Equatable {
    let text: String
    /// UTF-16 offset of the caret inside `text`.
    let cursor: Int
    let boldRange: NSRange?
}

/// Synthetic fixtures only. Templates: `**` toggles one bold span, `{cursor}`
/// marks the caret, `{arg}` inserts the prompted argument.
enum FixtureTable {
    struct Fixture {
        let keyword: String
        let template: String
        let hasArgument: Bool
    }

    static let defaultArgument = "Alex Fixture"
    static let all: [Fixture] = [
        Fixture(keyword: ";kl", template: "Hallo 👩🏽‍💻 **Keyloom**{cursor}!", hasArgument: false),
        Fixture(keyword: ";grüß", template: "Grüße{cursor} 😀", hasArgument: false),
        Fixture(keyword: ";hi", template: "Hi {arg}{cursor}!", hasArgument: true),
    ]
}

/// Bounded, immediate fixture-keyword recognizer over UTF-16 code units, the
/// unit Accessibility ranges use. Keeps only the most recent input.
final class Recognizer {
    static let bufferCapacity = 32

    /// (UTF-16 unit, units typed for it). A combining diaeresis typed after
    /// a/o/u folds into one precomposed unit that cost two typed units.
    private var recent: [(unit: UInt16, typed: Int)] = []
    private let keywords: [[UInt16]] = FixtureTable.all.map { Array($0.keyword.utf16) }

    var bufferedCount: Int { recent.count }

    func reset() { recent.removeAll(keepingCapacity: true) }

    /// Feeds units; returns the first keyword completed (units after it are dropped).
    /// Recognition is immediate, so a keyword that prefixes another always wins.
    func push(_ units: [UInt16]) -> KeywordMatch? {
        for unit in units {
            if let match = pushUnit(unit) { return match }
        }
        return nil
    }

    private func pushUnit(_ unit: UInt16) -> KeywordMatch? {
        if unit == 0x0308, let last = recent.last, let composed = Self.composeDiaeresis(last.unit) {
            recent[recent.count - 1] = (composed, last.typed + 1)
        } else {
            if recent.count == Self.bufferCapacity { recent.removeFirst() }
            recent.append((unit, 1))
        }
        return findKeyword()
    }

    private func findKeyword() -> KeywordMatch? {
        for (index, keyword) in keywords.enumerated() where recent.count >= keyword.count {
            let tail = recent.suffix(keyword.count)
            if tail.map(\.unit) == keyword {
                let typed = tail.reduce(0) { $0 + $1.typed }
                reset()
                return KeywordMatch(
                    keywordLength: typed, fixtureIndex: index, hasArgument: FixtureTable.all[index].hasArgument
                )
            }
        }
        return nil
    }

    private static func composeDiaeresis(_ base: UInt16) -> UInt16? {
        switch base {
        case 0x61: return 0xE4 // a -> ä
        case 0x6F: return 0xF6 // o -> ö
        case 0x75: return 0xFC // u -> ü
        case 0x41: return 0xC4 // A -> Ä
        case 0x4F: return 0xD6 // O -> Ö
        case 0x55: return 0xDC // U -> Ü
        default: return nil
        }
    }

    // MARK: Fixtures

    static func keyword(fixtureIndex: Int) -> String? {
        FixtureTable.all.indices.contains(fixtureIndex) ? FixtureTable.all[fixtureIndex].keyword : nil
    }

    /// An empty or nil argument renders the fixture's default. Nil for an
    /// unknown fixture or a malformed template (second cursor or bold span).
    static func render(fixtureIndex: Int, argument: String?) -> RenderedSnippet? {
        guard FixtureTable.all.indices.contains(fixtureIndex) else { return nil }
        let argument = (argument?.isEmpty ?? true) ? FixtureTable.defaultArgument : argument ?? ""
        var rest = Substring(FixtureTable.all[fixtureIndex].template)
        var text: [UInt16] = []
        var cursor: Int?
        var boldOpen: Int?
        var bold: (start: Int, length: Int)?
        while !rest.isEmpty {
            if rest.hasPrefix("**") {
                if let start = boldOpen {
                    bold = (start, text.count - start)
                    boldOpen = nil
                } else if bold != nil {
                    return nil
                } else {
                    boldOpen = text.count
                }
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("{cursor}") {
                guard cursor == nil else { return nil }
                cursor = text.count
                rest = rest.dropFirst("{cursor}".count)
            } else if rest.hasPrefix("{arg}") {
                text.append(contentsOf: argument.utf16)
                rest = rest.dropFirst("{arg}".count)
            } else {
                text.append(contentsOf: String(rest.removeFirst()).utf16)
            }
        }
        if let start = boldOpen { bold = (start, text.count - start) }
        return RenderedSnippet(
            text: String(decoding: text, as: UTF16.self),
            cursor: cursor ?? text.count,
            boldRange: bold.flatMap { $0.length > 0 ? NSRange(location: $0.start, length: $0.length) : nil }
        )
    }
}
