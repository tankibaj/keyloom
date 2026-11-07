import SwiftUI

/// What an import would do, entry by entry, before anything is written. Duplicates are skipped, a taken keyword
/// imports with expansion off, and unsupported placeholders stay as typed. Every state is a word, not a color.
struct ImportPreviewSheet: View {
    @Bindable var backups: SyncBackupsModel

    var body: some View {
        if let summary = backups.importPreview {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import Preview").font(.headline).accessibilityAddTraits(.isHeader)
                Text(headline(summary)).font(.callout).foregroundStyle(.secondary)
                List(summary.rows) { row in
                    HStack {
                        Toggle(isOn: Binding(get: { backups.selectedImportRows.contains(row.index) }, set: { _ in backups.toggleImportRow(row.index) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text(detail(row)).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!row.isSelectable)
                        .accessibilityIdentifier("settings.import.row.\(row.index)")
                    }
                }
                .frame(minHeight: 160)
                .accessibilityLabel("Entries in the file")
                if !summary.unsupportedTokens.isEmpty {
                    Label("Unsupported placeholders stay as typed: \(summary.unsupportedTokens.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .accessibilityIdentifier("settings.import.unsupported")
                }
                if summary.literalCount > 0 {
                    Label("\(summary.literalCount) \(summary.literalCount == 1 ? "snippet has" : "snippets have") placeholder syntax errors and import as plain text.",
                          systemImage: "exclamationmark.triangle").font(.callout)
                }
                if summary.malformedCount > 0 {
                    Label("\(summary.malformedCount) \(summary.malformedCount == 1 ? "entry" : "entries") in the file couldn’t be read and will be skipped.",
                          systemImage: "xmark.circle").font(.callout)
                }
                if let error = backups.errorMessage {
                    Label(error, systemImage: "xmark.octagon").font(.callout).accessibilityIdentifier("settings.import.error")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { backups.cancelImport() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("settings.import.cancel")
                    Button("Import \(backups.selectedImportRows.count) \(backups.selectedImportRows.count == 1 ? "Snippet" : "Snippets")") {
                        Task { await backups.commitImport() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(backups.selectedImportRows.isEmpty)
                    .accessibilityIdentifier("settings.import.confirm")
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }

    private func headline(_ summary: ImportPreviewSummary) -> String {
        let source = summary.format == .raycast ? "Raycast file" : "Keyloom file"
        return "\(source): \(summary.newCount) new, \(summary.conflictCount) with a keyword already in use, \(summary.duplicateCount) already here."
    }

    private func detail(_ row: ImportPreviewSummary.Row) -> String {
        let status = switch row.status {
        case .new: "New"
        case .duplicate: "Already here, skipped"
        case .keywordConflict: "Keyword already in use, imported with expansion off"
        }
        guard let keyword = row.keyword else { return status }
        return "\(status) · \(keyword)"
    }
}
