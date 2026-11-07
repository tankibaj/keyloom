import AppKit
import SwiftUI

/// The menu-bar popover. Behaves like a menu: the status row (with the one pause switch) first, search, snippet
/// rows with a keyword chip and ⌘1–9, then commands with their shortcuts. A missing Accessibility grant becomes one
/// actionable banner. Custom rows, not bordered buttons, so the panel reads as a menu bar extra and not a web card.
struct MenuBarView: View {
    @Bindable var model: MenuBarModel
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            if model.needsAccessibility { banner }
            searchField
            snippetSections
            callouts
            menuDivider
            commands
        }
        .padding(.vertical, 6)
        .frame(width: 340)
        .task {
            await model.refresh()
            searchFocused = true
        }
        .onChange(of: model.query) { Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: model.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
    }

    // MARK: Status and banner

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(model.status.title).fontWeight(.semibold)
            if model.status == .on {
                Text("Accessibility granted").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("Expansion", isOn: $model.isExpanding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.needsAccessibility)
                .accessibilityIdentifier("menubar.pause")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        switch model.status {
        case .on: .green
        case .paused: Color(nsColor: .tertiaryLabelColor)
        case .needsAccessibility: .orange
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Typing expansion is off").fontWeight(.semibold)
            Text("Keyloom needs Accessibility to see the keyword you type. It never reads or stores your text.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { model.openAccessibilitySettings() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 6)
                .accessibilityIdentifier("menubar.openAccessibility")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.14), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.banner")
    }

    // MARK: Search and snippets

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find a snippet", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("menubar.search")
            if let hint = model.pickerShortcutHint {
                Keycap(text: hint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var snippetSections: some View {
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        if searching && model.pinned.isEmpty && model.recents.isEmpty {
            Text("No snippets match.").foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        } else {
            if !model.pinned.isEmpty || !searching {
                sectionHeader("Pinned")
                if model.pinned.isEmpty {
                    Text("Nothing pinned yet. Right-click a snippet in the Library and choose Pin.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                ForEach(model.pinnedItems) { snippetRow($0) }
            }
            if !model.recents.isEmpty {
                sectionHeader("Recently Used")
                ForEach(model.recentItems) { snippetRow($0) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func snippetRow(_ item: MenuBarModel.PopoverRow) -> some View {
        MenuRowButton(action: { Task { await model.insert(item.id) } }) { highlighted in
            SnippetIconView(icon: item.row.icon)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .background(highlighted ? Color.white.opacity(0.2) : Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
            Text(item.row.name).lineLimit(1)
            Spacer(minLength: 8)
            if let chip = item.chip {
                Keycap(text: chip, highlighted: highlighted)
            }
            if let hint = item.shortcutHint {
                Text(hint).font(.callout)
                    .foregroundStyle(highlighted ? AnyShapeStyle(onAccent.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .modifier(NumberShortcut(number: item.number))
        .accessibilityLabel(item.row.accessibilityLabel)
        .accessibilityIdentifier("menubar.snippet.\(item.id.uuidString)")
    }

    // MARK: Notices

    @ViewBuilder
    private var callouts: some View {
        if let warning = model.shortcutWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 8)
                .accessibilityIdentifier("menubar.shortcutWarning")
        }
        if let notice = model.notice {
            Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 8)
                .accessibilityIdentifier("menubar.notice")
        }
        if model.hasCopyOffer {
            MenuRowButton(action: { model.copyRefused() }) { _ in
                Image(systemName: "doc.on.doc").frame(width: 16)
                Text("Copy the Snippet That Wasn’t Inserted")
            }
            .padding(.top, 4)
            .accessibilityIdentifier("menubar.copyRefused")
        }
    }

    // MARK: Commands

    private var menuDivider: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            command("Open Library", symbol: "books.vertical", shortcut: "⌘L", id: "openLibrary") { showLibrary() }
                .keyboardShortcut("l", modifiers: .command)
            if model.showsExpansionCommands {
                command("New Snippet…", symbol: "square.and.pencil", shortcut: "⌘N", id: "newSnippet") {
                    showLibrary()
                    Task { await app.requestNewSnippet() }
                }
                .keyboardShortcut("n", modifiers: .command)
                command("Open Picker", symbol: "magnifyingglass", shortcut: model.pickerShortcutHint, id: "openPicker") { model.openPicker() }
            }
            menuDivider
            command("Settings…", symbol: "gearshape", shortcut: "⌘,", id: "settings") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            command("Quit Keyloom", symbol: nil, shortcut: "⌘Q", id: "quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func command(_ title: String, symbol: String?, shortcut: String?, id: String, action: @escaping () -> Void) -> some View {
        MenuRowButton(action: action) { highlighted in
            Image(systemName: symbol ?? "circle").opacity(symbol == nil ? 0 : 1)
                .frame(width: 16)
                .foregroundStyle(highlighted ? AnyShapeStyle(onAccent) : AnyShapeStyle(.secondary))
            Text(title)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut).foregroundStyle(highlighted ? AnyShapeStyle(onAccent) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityIdentifier("menubar.\(id)")
    }

    private func showLibrary() {
        NSApp.activate()
        openWindow(id: "library")
    }
}

private let onAccent = Color(nsColor: .selectedMenuItemTextColor)

/// ⌘1 to ⌘9 inserts that row. Rows past the ninth have none.
private struct NumberShortcut: ViewModifier {
    let number: Int?

    func body(content: Content) -> some View {
        if let number, let character = String(number).first {
            content.keyboardShortcut(KeyEquivalent(character), modifiers: .command)
        } else {
            content
        }
    }
}

/// A menu-style row: full-width hit area, accent highlight under the pointer with on-accent text, like an NSMenu item.
private struct MenuRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content(hovered) }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(hovered ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
                .background(hovered ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovered = $0 }
    }
}

/// A keycap: a keyword or shortcut in a small monospaced chip.
private struct Keycap: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor).opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(highlighted ? Color.white.opacity(0.22) : Color.primary.opacity(0.08), in: .rect(cornerRadius: 5))
            .lineLimit(1)
    }
}
