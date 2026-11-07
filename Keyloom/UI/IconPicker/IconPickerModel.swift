import Foundation

/// The icon picker's state and rules, apart from the view: which kind is showing, the search, and what a
/// choice does to the icon. `icon` is what the editor stores; the view writes it back after each change.
struct IconPickerModel: Equatable {
    enum Mode: Equatable { case emoji, symbols }
    enum Direction { case left, right, up, down }

    static let columns = 8

    private(set) var icon: SnippetIcon
    var mode: Mode
    var query = ""
    /// The tint while an emoji is the icon, so the color picked then comes back with the next symbol.
    private var pendingColor: IconColor?

    init(icon: SnippetIcon) {
        self.icon = icon
        switch icon {
        case .emoji: mode = .emoji
        case .symbol(_, let color): mode = .symbols; pendingColor = color
        }
    }

    var selectedSymbol: String? {
        if case .symbol(let name, _) = icon { name } else { nil }
    }

    var selectedColor: IconColor? {
        if case .symbol(_, let color) = icon { color } else { pendingColor }
    }

    var visibleSections: [SymbolSection] { SymbolCatalog.sections(matching: query) }
    var hasNoMatches: Bool { visibleSections.isEmpty }

    mutating func select(symbol name: String) {
        icon = .symbol(name, color: selectedColor)
    }

    /// Choosing the chosen color again goes back to the default tint. An emoji ignores color: the choice waits
    /// for the next symbol.
    mutating func select(color: IconColor) {
        let next = selectedColor == color ? nil : color
        pendingColor = next
        if case .symbol(let name, _) = icon { icon = .symbol(name, color: next) }
    }

    mutating func select(emoji: String) {
        icon = .emoji(emoji)
    }

    /// Applies typed text when it is exactly one emoji.
    mutating func applyTyped(_ text: String) -> Bool {
        guard let chosen = IconCatalog.emoji(from: text) else { return false }
        icon = chosen
        return true
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
