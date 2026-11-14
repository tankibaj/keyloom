import AppKit
import SwiftUI

/// The icon popover, after the Shortcuts glyph picker: a color row, a search field (focused on open) and a grid
/// of SF Symbols under uppercase section headers. Choices apply at once. Arrow keys move through the grid,
/// Return or Space chooses, Escape closes.
struct IconPickerView: View {
    @Binding var icon: SnippetIcon
    @State private var model: IconPickerModel
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case search
        case symbol(String)
    }

    private let columns = Array(repeating: GridItem(.flexible(minimum: 28), spacing: 4), count: IconPickerModel.columns)

    init(icon: Binding<SnippetIcon>) {
        _icon = icon
        _model = State(initialValue: IconPickerModel(icon: icon.wrappedValue))
    }

    var body: some View {
        symbolsPane
        .padding(16)
        .frame(width: 320, height: 420)
        .onExitCommand { dismiss() }
        .onAppear { focus = .search }
        .onChange(of: model.icon) { _, chosen in icon = chosen }
        .onChange(of: model.hasNoMatches) { _, none in
            if none { AccessibilityNotification.Announcement("No symbols match").post() }
        }
    }

    // MARK: Symbols

    private var symbolsPane: some View {
        VStack(spacing: 12) {
            colorRow
            TextField("Search Symbols", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) {
                    guard let first = model.visibleSections.first?.symbols.first else { return .ignored }
                    focus = .symbol(first.name)
                    return .handled
                }
                .accessibilityLabel("Search Symbols")
                .accessibilityIdentifier("icon.search")
            symbolGrid
        }
    }

    private var colorRow: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(IconColor.allCases, id: \.self) { color in
                let selected = model.selectedColor == color
                Button { model.select(color: color) } label: {
                    ZStack {
                        Circle().fill(color.color)
                        if selected {
                            Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 1)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.displayName)
                .accessibilityHint(selected ? "Selected. Choose again to use the default color." : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("icon.color.\(color.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color")
    }

    @ViewBuilder private var symbolGrid: some View {
        if model.hasNoMatches {
            ContentUnavailableView("No symbols match", systemImage: "magnifyingglass",
                                   description: Text("Nothing is named or described “\(model.query)”."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.visibleSections) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: 4) {
                                    ForEach(section.symbols, id: \.name) { entry in symbolCell(entry) }
                                }
                            } header: {
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .background(.bar)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                }
                .onChange(of: focus) { _, field in
                    if case .symbol(let name) = field { proxy.scrollTo(name) }
                }
                .onKeyPress(.leftArrow) { move(.left) }
                .onKeyPress(.rightArrow) { move(.right) }
                .onKeyPress(.upArrow) { move(.up) }
                .onKeyPress(.downArrow) { move(.down) }
                .onKeyPress(.return) { chooseFocused() }
            }
        }
    }

    private func symbolCell(_ entry: SymbolEntry) -> some View {
        cell(selected: model.selectedSymbol == entry.name, label: entry.label, id: "icon.symbol.\(entry.name)") {
            model.select(symbol: entry.name)
        } content: {
            Image(systemName: entry.name).foregroundStyle(model.selectedColor?.color ?? Color.primary)
        }
        .focused($focus, equals: .symbol(entry.name))
        .id(entry.name)
        .help(entry.label)
    }

    private func cell<Content: View>(selected: Bool, label: String, id: String, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .font(.title3)
                .frame(width: 32, height: 32)
                .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func move(_ direction: IconPickerModel.Direction) -> KeyPress.Result {
        guard case .symbol(let name) = focus else { return .ignored }
        if let next = IconPickerModel.neighbor(of: name, direction, in: model.visibleSections) {
            focus = .symbol(next)
        } else if direction == .up {
            focus = .search
        }
        return .handled
    }

    private func chooseFocused() -> KeyPress.Result {
        guard case .symbol(let name) = focus else { return .ignored }
        model.select(symbol: name)
        return .handled
    }
}
