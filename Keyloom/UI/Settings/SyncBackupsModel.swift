import Foundation
import Observation

/// A file ready to be saved: the view hands it to the system save panel.
struct ExportFile: Equatable {
    let data: Data
    let filename: String
}

/// A Raycast export and what it cannot carry, shown before the user saves.
struct RaycastExportPlan: Equatable {
    let file: ExportFile
    /// Snippets affected, per kind of loss.
    let lossCounts: [LossKind: Int]
    var hasLoss: Bool { !lossCounts.isEmpty }
}

/// The import preview sheet's content: one row per file entry, with what the import would do to it. Names and
/// counts only, no template text.
struct ImportPreviewSummary: Equatable {
    enum Status: Equatable {
        case new
        /// Same content as a snippet already here: skipped.
        case duplicate
        /// Its keyword belongs to another enabled snippet: imported with expansion off.
        case keywordConflict
    }

    struct Row: Identifiable, Equatable {
        let index: Int
        let name: String
        let keyword: String?
        let status: Status
        /// Tokens this version cannot interpret; they stay in the text as typed.
        let unsupportedTokens: [String]
        let keptLiteral: Bool
        var id: Int { index }
        var isSelectable: Bool { status != .duplicate }
    }

    let format: ImportFormat
    let rows: [Row]
    /// Entries of the file that could not be read at all.
    let malformedCount: Int

    init(_ preview: ImportPreview) {
        format = preview.format
        malformedCount = preview.malformed.count
        rows = preview.items.map { item in
            let status: Status = item.duplicateOf != nil ? .duplicate : (item.conflictsWith != nil ? .keywordConflict : .new)
            return Row(index: item.index, name: item.snippet.name, keyword: item.snippet.keyword, status: status,
                       unsupportedTokens: item.unsupportedTokens, keptLiteral: item.templateKeptLiteral)
        }
    }

    var newCount: Int { rows.filter { $0.status == .new }.count }
    var duplicateCount: Int { rows.filter { $0.status == .duplicate }.count }
    var conflictCount: Int { rows.filter { $0.status == .keywordConflict }.count }
    /// Across the entries that would import, in file order, without repeats.
    var unsupportedTokens: [String] {
        var seen = Set<String>()
        return rows.filter(\.isSelectable).flatMap(\.unsupportedTokens).filter { seen.insert($0).inserted }
    }
    var literalCount: Int { rows.filter { $0.isSelectable && $0.keptLiteral }.count }
}

struct SnapshotRow: Identifiable, Equatable {
    let info: SnapshotInfo
    var id: URL { info.url }
    var kind: SnapshotKind { info.kind }
    var createdAt: Date { info.createdAt }

    var title: String {
        switch info.kind {
        case .daily: "Daily"
        case .preImport: "Before import"
        case .preRestore: "Before restore"
        }
    }
}

/// Settings > Sync & Backups: import and export, the snapshot list and restore. Everything goes through the
/// library's own transactions; a failure leaves the library as it was and is shown, never swallowed. Messages
/// carry counts and names of snapshots, never snippet text.
@MainActor @Observable
final class SyncBackupsModel {
    private(set) var importPreview: ImportPreviewSummary?
    private(set) var selectedImportRows: Set<Int> = []
    private(set) var snapshotRows: [SnapshotRow] = []
    private(set) var pendingRestore: SnapshotRow?
    /// The last outcome worth saying; announced to VoiceOver by the view.
    private(set) var message: String?
    var errorMessage: String?

    @ObservationIgnored private let library: SnippetLibrary
    @ObservationIgnored private let snapshots: SnapshotManager
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var preview: ImportPreview?

    init(library: SnippetLibrary, snapshots: SnapshotManager, now: @escaping () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.library = library
        self.snapshots = snapshots
        self.now = now
        self.calendar = calendar
    }

    // MARK: Import

    /// Reads a file chosen by the user. Oversized files are refused before they are read into memory.
    func loadImport(url: URL) async {
        resetMessages()
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ImportLimits.maxFileBytes else { throw PortabilityError.fileTooLarge(maximumBytes: ImportLimits.maxFileBytes) }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            await loadImport(data: data)
        } catch let error as PortabilityError {
            errorMessage = UserMessage.describe(error)
        } catch {
            errorMessage = "Keyloom couldn’t read that file."
        }
    }

    func loadImport(data: Data) async {
        resetMessages()
        do {
            let planned = try await library.previewImport(data)
            preview = planned
            importPreview = ImportPreviewSummary(planned)
            selectedImportRows = Set(planned.importable.map(\.index))
        } catch {
            errorMessage = UserMessage.describe(error)
        }
    }

    func toggleImportRow(_ index: Int) {
        guard importPreview?.rows.first(where: { $0.index == index })?.isSelectable == true else { return }
        if selectedImportRows.contains(index) { selectedImportRows.remove(index) } else { selectedImportRows.insert(index) }
    }

    /// One transaction, after a pre-import snapshot. On failure nothing was imported and the sheet stays open.
    func commitImport() async {
        guard let preview else { return }
        errorMessage = nil
        do {
            let outcome = try await library.commitImport(preview, selecting: selectedImportRows, snapshots: snapshots)
            let count = outcome.imported.count
            var text = "Imported \(count) \(count == 1 ? "snippet" : "snippets")"
            if !outcome.disabledForKeywordConflict.isEmpty {
                text += " (\(outcome.disabledForKeywordConflict.count) off because the keyword is already in use)"
            }
            message = text + "."
            cancelImport()
            await refreshSnapshots()
        } catch {
            errorMessage = UserMessage.describe(error)
        }
    }

    func cancelImport() {
        preview = nil
        importPreview = nil
        selectedImportRows = []
    }

    // MARK: Export

    func exportNative() async -> ExportFile? {
        resetMessages()
        do {
            return ExportFile(data: try await library.exportNative(), filename: "Keyloom Snippets \(dateStamp).json")
        } catch {
            errorMessage = UserMessage.describe(error)
            return nil
        }
    }

    func prepareRaycastExport() async -> RaycastExportPlan? {
        resetMessages()
        do {
            let export = try await library.exportRaycast()
            var counts: [LossKind: Int] = [:]
            for kind in export.losses.flatMap(\.kinds) { counts[kind, default: 0] += 1 }
            return RaycastExportPlan(file: ExportFile(data: export.data, filename: "Keyloom Snippets (Raycast) \(dateStamp).json"),
                                     lossCounts: counts)
        } catch {
            errorMessage = UserMessage.describe(error)
            return nil
        }
    }

    // MARK: Snapshots

    func refreshSnapshots() async {
        do {
            snapshotRows = try await snapshots.list().map(SnapshotRow.init)
        } catch {
            errorMessage = UserMessage.describe(error)
        }
    }

    /// The same daily snapshot the app takes at launch: at most one per day, and only when the library changed.
    func backUpNow() async {
        resetMessages()
        do {
            message = try await library.takeDailySnapshot(using: snapshots) == nil
                ? "No new backup: nothing has changed since the last daily snapshot, or today’s is already saved."
                : "Daily snapshot saved."
        } catch {
            errorMessage = UserMessage.describe(error)
        }
        await refreshSnapshots()
    }

    func requestRestore(_ row: SnapshotRow) { pendingRestore = row }

    func cancelRestore() { pendingRestore = nil }

    /// After the confirmation: validates the snapshot, saves the current library as a pre-restore snapshot, then
    /// restores in one transaction. A damaged snapshot changes nothing.
    func confirmRestore() async {
        guard let row = pendingRestore else { return }
        pendingRestore = nil
        resetMessages()
        do {
            let outcome = try await library.restore(from: row.info, using: snapshots)
            var text = "Restored the library from \(row.createdAt.formatted(date: .abbreviated, time: .shortened)): "
                + "\(outcome.created.count) added, \(outcome.updated.count) updated, \(outcome.deleted.count) removed."
            if !outcome.disabledForKeywordConflict.isEmpty {
                text += " \(outcome.disabledForKeywordConflict.count) set to expansion off because their keyword is in use."
            }
            message = text + " Your previous library was saved as a snapshot first."
        } catch {
            errorMessage = UserMessage.describe(error)
        }
        await refreshSnapshots()
    }

    // MARK: Private

    private func resetMessages() {
        message = nil
        errorMessage = nil
    }

    private var dateStamp: String {
        now().formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }
}
