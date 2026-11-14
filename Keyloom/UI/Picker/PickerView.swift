import AppKit
import SwiftUI

/// The global quick picker: search at the top, matches on the left, preview on the right. Return copies the
/// selection and closes, arrows move, Escape closes.
struct PickerView: View {
    @Bindable var model: PickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 700, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onExitCommand { model.cancel() }
        .onAppear { searchFocused = true }
        .onChange(of: model.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search snippets", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { Task { await submit() } }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .accessibilityIdentifier("picker.search")
            Text("esc").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        switch model.emptyState {
        case .emptyLibrary:
            ContentUnavailableView("No Snippets Yet", systemImage: "text.bubble",
                                   description: Text("Create a snippet in the Keyloom library, then it appears here."))
        case .noResults(let query):
            ContentUnavailableView.search(text: query)
        case nil:
            HStack(spacing: 0) {
                matches
                Divider()
                previewPane
            }
        }
    }

    private var matches: some View {
        ScrollViewReader { proxy in
            List(model.rows, selection: $model.selection) { row in
                SnippetRowView(row: row).tag(row.id)
            }
            .contextMenu(forSelectionType: UUID.self) { _ in
                Button("Copy") { Task { await model.copySelected() } }
            } primaryAction: { _ in
                Task { await submit() }
            }
            .accessibilityLabel("Snippets")
            .accessibilityIdentifier("picker.list")
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(width: 280)
    }

    private var previewPane: some View {
        ScrollView {
            Group {
                switch model.preview {
                case .rendered(let rendered)?: Text(PreviewText.attributed(rendered))
                case .unavailable(let message)?: Text(message).foregroundStyle(.secondary)
                case nil: EmptyView()
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .accessibilityLabel("Preview")
        .accessibilityIdentifier("picker.preview")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("picker.notice")
            }
            Spacer(minLength: 0)
            Text("Return to copy").font(.caption).foregroundStyle(.secondary)
            Button("Copy") { Task { await model.copySelected() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCopy)
                .help("Copy to the clipboard (↩)")
                .accessibilityIdentifier("picker.copy")
        }
        .padding(10)
    }

    private func submit() async { await model.copySelected() }
}

/// A borderless floating panel centred in the upper third of the screen the pointer is on.
@MainActor
final class PickerPanelPresenter: NSObject, PickerPanelPresenting, NSWindowDelegate {
    private var panel: FloatingPanel?
    private weak var model: PickerModel?

    func show(_ model: PickerModel) {
        self.model = model
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: PickerView(model: model))
        position(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    /// Clicking away abandons the session without returning focus: the user chose where to go.
    func windowDidResignKey(_ notification: Notification) { hide() }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                                  styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.model?.cancel() }
        panel.setAccessibilityLabel("Keyloom quick picker")
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return panel.center() }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height / 4 - panel.frame.height / 2))
    }
}
