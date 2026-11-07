import Foundation

/// The icon picker's state and rules, apart from the view: the search and what a choice does to the icon.
/// `icon` is what the editor stores; the view writes it back after each change. Symbols and colors only: an
/// emoji icon from older data is shown as `fallbackSymbol` and stays stored as it is until a choice replaces it.
struct IconPickerModel: Equatable {
    enum Direction { case left, right, up, down }

    static let columns = 8

    /// What an emoji icon (older data) is drawn as, and what a color choice turns it into.
    static let fallbackSymbol = "doc.text"

    private(set) var icon: SnippetIcon
    var query = ""

    init(icon: SnippetIcon) {
        self.icon = icon
    }

    var selectedSymbol: String? {
        if case .symbol(let name, _) = icon { name } else { nil }
    }

    var selectedColor: IconColor? {
        if case .symbol(_, let color) = icon { color } else { nil }
    }

    var visibleSections: [SymbolSection] { SymbolCatalog.sections(matching: query) }
    var hasNoMatches: Bool { visibleSections.isEmpty }

    mutating func select(symbol name: String) {
        icon = .symbol(name, color: selectedColor)
    }

    /// Choosing the chosen color again goes back to the default tint. An emoji icon becomes the fallback symbol
    /// in the chosen color.
    mutating func select(color: IconColor) {
        let next = selectedColor == color ? nil : color
        icon = .symbol(selectedSymbol ?? Self.fallbackSymbol, color: next)
    }

    /// The symbol an arrow key moves to from `name`: left and right in reading order across sections, up and down
    /// by one row of `columns` within the section, then into the neighboring section, clamped to a short row.
    static func neighbor(of name: String, _ direction: Direction, in sections: [SymbolSection]) -> String? {
        guard let s = sections.firstIndex(where: { $0.symbols.contains { $0.name == name } }),
              let index = sections[s].symbols.firstIndex(where: { $0.name == name }) else { return nil }
        func pick(_ section: Int, _ row: Int, _ column: Int) -> String {
            let count = sections[section].symbols.count
            return sections[section].symbols[min(row * columns + column, count - 1)].name
        }
        let row = index / columns, column = index % columns
        let lastRow = (sections[s].symbols.count - 1) / columns
        switch direction {
        case .right:
            if index + 1 < sections[s].symbols.count { return sections[s].symbols[index + 1].name }
            return s + 1 < sections.count ? sections[s + 1].symbols[0].name : nil
        case .left:
            if index > 0 { return sections[s].symbols[index - 1].name }
            return s > 0 ? sections[s - 1].symbols.last?.name : nil
        case .down:
            if row < lastRow { return pick(s, row + 1, column) }
            return s + 1 < sections.count ? pick(s + 1, 0, column) : nil
        case .up:
            if row > 0 { return pick(s, row - 1, column) }
            guard s > 0 else { return nil }
            return pick(s - 1, (sections[s - 1].symbols.count - 1) / columns, column)
        }
    }
}
