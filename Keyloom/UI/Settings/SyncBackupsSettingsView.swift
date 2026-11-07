import SwiftUI
import UniformTypeIdentifiers

/// A JSON file for `fileExporter`.
struct JSONFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Settings > Sync & Backups: the iCloud switch, import and export, and snapshots with restore.
struct SyncBackupsSettingsView: View {
    let sync: any SyncSettingsProviding
    @Bindable var backups: SyncBackupsModel
    let snapshotError: String?

    @State private var importing = false
    @State private var exportFile: ExportFile?
    @State private var raycastPlan: RaycastExportPlan?

    var body: some View {
        Form {
            iCloudSection
            portabilitySection
            snapshotsSection
        }
        .formStyle(.grouped)
        .task { await backups.refreshSnapshots() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await load(url) }
            case .failure: backups.errorMessage = "Keyloom couldn’t open that file."
            }
        }
        .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      document: JSONFileDocument(data: exportFile?.data ?? Data()), contentType: .json,
                      defaultFilename: exportFile?.filename ?? "Keyloom Snippets") { result in
            if case .failure = result { backups.errorMessage = "Keyloom couldn’t save the file." }
        }
        .sheet(isPresented: Binding(get: { backups.importPreview != nil }, set: { if !$0 { backups.cancelImport() } })) {
            ImportPreviewSheet(backups: backups)
        }
        .confirmationDialog("Export to Raycast format?", isPresented: Binding(get: { raycastPlan != nil }, set: { if !$0 { raycastPlan = nil } }),
                            titleVisibility: .visible, presenting: raycastPlan) { plan in
            Button("Save…") { exportFile = plan.file }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(Self.lossDescription(plan))
        }
        .confirmationDialog("Restore this snapshot?", isPresented: Binding(get: { backups.pendingRestore != nil }, set: { if !$0 { backups.cancelRestore() } }),
                            titleVisibility: .visible, presenting: backups.pendingRestore) { _ in
            Button("Restore", role: .destructive) { Task { await backups.confirmRestore() } }
            Button("Cancel", role: .cancel) { backups.cancelRestore() }
        } message: { _ in
            Text("Your current library is saved as a snapshot first. Snippets added since this snapshot are removed, and the changes sync to your other Macs when iCloud Sync is on.")
        }
        .alert("Couldn’t Complete That", isPresented: Binding(get: { backups.errorMessage != nil && backups.importPreview == nil },
                                                              set: { if !$0 { backups.errorMessage = nil } })) {
            Button("OK") { backups.errorMessage = nil }
        } message: {
            Text(backups.errorMessage ?? "")
        }
        .onChange(of: backups.message) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private var iCloudSection: some View {
        Section("iCloud Sync") {
            Toggle("iCloud Sync", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                .accessibilityIdentifier("settings.sync.toggle")
            Label(SyncCopy.description(for: sync.status), systemImage: SyncCopy.symbol(for: sync.status))
                .accessibilityIdentifier("settings.sync.status")
            Text("This choice applies to this Mac only. Writing-assistance settings are never synced.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var portabilitySection: some View {
        Section("Import & Export") {
            Button("Import…") { importing = true }
                .accessibilityIdentifier("settings.import.button")
            Button("Export Keyloom Snippets…") { Task { exportFile = await backups.exportNative() } }
                .accessibilityIdentifier("settings.export.native")
            Button("Export for Raycast…") {
                Task {
                    guard let plan = await backups.prepareRaycastExport() else { return }
                    if plan.hasLoss { raycastPlan = plan } else { exportFile = plan.file }
                }
            }
            .accessibilityIdentifier("settings.export.raycast")
            if let message = backups.message {
                Text(message).font(.callout).accessibilityIdentifier("settings.backups.message")
            }
        }
    }

    private var snapshotsSection: some View {
        Section("Snapshots") {
            Button("Back Up Now") { Task { await backups.backUpNow() } }
                .accessibilityIdentifier("settings.snapshots.backup")
            if let snapshotError {
                Label("The daily snapshot at launch failed: \(snapshotError)", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .accessibilityIdentifier("settings.snapshots.launchError")
            }
            if backups.snapshotRows.isEmpty {
                Text("No snapshots yet. Keyloom saves one each day your snippets change.").foregroundStyle(.secondary)
            }
            ForEach(Array(backups.snapshotRows.enumerated()), id: \.element.id) { offset, row in
                LabeledContent {
                    Button("Restore…") { backups.requestRestore(row) }
                        .accessibilityLabel("Restore \(row.title) snapshot from \(row.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityIdentifier("settings.snapshots.restore.\(offset)")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        Text(row.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Keeps 30 daily snapshots and the latest 10 taken before an import or restore.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func load(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await backups.loadImport(url: url)
    }

    static func lossDescription(_ plan: RaycastExportPlan) -> String {
        let names: [(LossKind, String)] = [(.textStyles, "bold, italic or underline"), (.listFormatting, "lists"),
                                           (.tags, "tags"), (.pinned, "pinned state"), (.disabled, "the expansion on/off switch")]
        let parts = names.compactMap { kind, label in plan.lossCounts[kind].map { "\(label) (\($0))" } }
        return "Raycast keeps only each snippet’s name, text and keyword. This export drops: " + parts.joined(separator: ", ") + "."
    }
}
