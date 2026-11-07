import AppKit
import SwiftUI

/// The menu-bar popover: search, pinned and recent snippets, then the library, picker, pause and Settings.
struct MenuBarView: View {
    @Bindable var model: MenuBarModel
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find a snippet", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("menubar.search")
            section("Pinned", rows: model.pinned, empty: "Nothing pinned yet. Pin a snippet in the library.")
            section("Recently Used", rows: model.recents, empty: "Nothing used yet.")
            if let warning = model.shortcutWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menubar.shortcutWarning")
            }
            if let notice = model.notice {
                Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menubar.notice")
            }
            if model.hasCopyOffer {
                Button("Copy the Snippet That Wasn’t Inserted") { model.copyRefused() }
                    .accessibilityIdentifier("menubar.copyRefused")
            }
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 320)
        .task { await model.refresh() }
        .onChange(of: model.query) { Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: model.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
    }

    private func section(_ title: String, rows: [SnippetRow], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(rows) { row in
                Button { Task { await model.insert(row.id) } } label: {
                    SnippetRowView(row: row).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menubar.snippet.\(row.id.uuidString)")
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Pause expansion", isOn: $model.isPaused)
                .toggleStyle(.switch)
                .accessibilityIdentifier("menubar.pause")
            HStack {
                Button("Open Library") { showLibrary() }
                    .accessibilityIdentifier("menubar.openLibrary")
                Button("New Snippet") {
                    showLibrary()
                    Task { await app.requestNewSnippet() }
                }
                .accessibilityIdentifier("menubar.newSnippet")
            }
            HStack {
                Button("Open Picker") { model.openPicker() }
                    .accessibilityIdentifier("menubar.openPicker")
                Spacer()
                Button("Settings…", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("menubar.settings")
            }
        }
    }

    private func showLibrary() {
        NSApp.activate()
        openWindow(id: "library")
    }
}
