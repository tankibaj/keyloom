import SwiftUI

/// Settings, Sync & Backups, iCloud Sync. A `Section` to place inside the panel's grouped `Form` (the
/// settings scene owns the form and the Backups section next to it).
///
/// Accessibility: the switch and button are native controls with visible labels (so keyboard and VoiceOver
/// work as for any Settings pane, with the system focus ring); the status line pairs an SF Symbol with text,
/// so no state depends on color; a change of status is announced; text wraps at any width and uses the
/// system styles, which follow contrast and Dynamic Type settings.
struct SyncSettingsView: View {
    @Bindable var model: SyncSettingsViewModel

    var body: some View {
        Section {
            Toggle("Sync snippets through iCloud on this Mac", isOn: Binding(
                get: { model.isEnabled },
                set: { newValue in Task { await model.setEnabled(newValue) } }))
            .task { await model.observe() }

            VStack(alignment: .leading, spacing: 4) {
                Label(model.presentation.text, systemImage: model.presentation.symbol)
                    .font(.headline)
                Text(model.presentation.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let pending = model.pendingNote { Text(pending).foregroundStyle(.secondary) }
                if let conflicts = model.keywordConflictNote {
                    Label(conflicts, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let newer = model.newerSchemaNote {
                    Label(newer, systemImage: "arrow.down.app").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let skipped = model.skippedNote {
                    Label(skipped, systemImage: "info.circle").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .onChange(of: model.presentation.text) { _, announcement in
                AccessibilityNotification.Announcement(announcement).post()
            }

            Button("Sync Now") { Task { await model.syncNow() } }
                .disabled(!model.presentation.canSyncNow)
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text(SyncStatusPresentation.localLibraryNote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
