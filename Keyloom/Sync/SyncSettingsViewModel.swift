import Foundation
import Observation

/// How a sync status reads in Settings. A pure function of the status, so every state is covered by a plain test.
struct SyncStatusPresentation: Equatable {
    /// Shown in every state: the guarantee, in the user's words.
    static let localLibraryNote = String(localized: "Your snippets stay available on this Mac whatever iCloud is doing. Turning sync off keeps your snippets here and in iCloud.")

    let status: SyncStatus

    init(_ status: SyncStatus) { self.status = status }

    /// A build iCloud was never set up for: the switch cannot do anything, so it shows off and is disabled.
    var isUnsupportedBuild: Bool { status == .unavailable(.buildNotProvisioned) }

    /// Sync Now is offered only when it can do something; the switch is always available except on an unsupported build.
    var canSyncNow: Bool {
        switch status {
        case .upToDate, .quotaExceeded, .failed: true
        case .off, .checkingAccount, .signedOut, .unavailable, .syncing: false
        }
    }

    /// An SF Symbol per state, so state is never conveyed by color alone.
    var symbol: String {
        switch status {
        case .off: "icloud.slash"
        case .checkingAccount, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .unavailable, .failed: "exclamationmark.icloud"
        case .upToDate: "checkmark.icloud"
        case .quotaExceeded: "exclamationmark.triangle"
        }
    }

    var text: String {
        switch status {
        case .off: String(localized: "iCloud Sync is off")
        case .checkingAccount: String(localized: "Checking iCloud account…")
        case .signedOut: String(localized: "Not signed in to iCloud")
        case .unavailable(.restricted): String(localized: "iCloud is restricted on this Mac")
        case .unavailable(.temporarilyUnavailable): String(localized: "iCloud is temporarily unavailable")
        case .unavailable(.buildNotProvisioned): String(localized: "iCloud Sync is not available in this build")
        case .syncing: String(localized: "Syncing…")
        case .upToDate: String(localized: "Up to date")
        case .quotaExceeded: String(localized: "iCloud storage is full")
        case .failed(.network): String(localized: "Can't reach iCloud")
        case .failed(.recordTooLarge): String(localized: "A snippet is too large to sync")
        case .failed(.localStorage): String(localized: "Sync could not use the local library")
        case .failed(.unexpected(let code)): String(localized: "Sync stopped (error \(code))")
        }
    }

    /// What the user can do about it, or what happens next.
    var detail: String {
        switch status {
        case .off: String(localized: "Turn on to sync your snippets through your private iCloud account.")
        case .checkingAccount, .syncing: String(localized: "Changes made now are saved on this Mac and sent when syncing finishes.")
        case .signedOut: String(localized: "Sign in to iCloud in System Settings. Sync starts when you do.")
        case .unavailable(.restricted): String(localized: "iCloud is turned off for this Mac by a restriction. Sync resumes if it is allowed again.")
        case .unavailable(.temporarilyUnavailable): String(localized: "Sync resumes when iCloud is available again.")
        case .unavailable(.buildNotProvisioned): String(localized: "This build is not signed for iCloud. Use the released app to sync.")
        case .upToDate(let date): String(localized: "Last synced \(date.formatted(.relative(presentation: .named)))")
        case .quotaExceeded: String(localized: "Changes are saved on this Mac and upload when there is space. Free up iCloud storage, then choose Sync Now.")
        case .failed: String(localized: "Changes are saved on this Mac. Choose Sync Now to try again.")
        }
    }
}

/// State and actions behind Settings, Sync & Backups, iCloud Sync (`SyncSettingsView`). It only reads the
/// controller's status and forwards the user's actions; it holds no library data, so it can never make local
/// editing, backups or expansion wait on iCloud. Every sync state is a plain value, never an error thrown at
/// local callers.
@MainActor
@Observable
final class SyncSettingsViewModel {
    private let controller: SyncController
    private let preference: SyncPreference

    /// The switch as the user sees it; follows the saved choice.
    private(set) var isEnabled: Bool
    private(set) var status: SyncStatus = .off
    private(set) var pendingChanges = 0
    private(set) var skippedRemoteRecords = 0
    private(set) var keywordConflictCount = 0
    private(set) var newerSchemaCount = 0

    init(controller: SyncController, preference: SyncPreference = SyncPreference()) {
        self.controller = controller
        self.preference = preference
        isEnabled = preference.isEnabled
    }

    var presentation: SyncStatusPresentation { SyncStatusPresentation(status) }

    /// Shown only when remote records were left untouched.
    var skippedNote: String? {
        skippedRemoteRecords == 0 ? nil
            : String(localized: "\(skippedRemoteRecords) iCloud snippets could not be read by this version of Keyloom and were left untouched.")
    }

    /// Shown while snippets a newer Keyloom wrote wait for an update; they are fetched again once this build can read them.
    var newerSchemaNote: String? {
        newerSchemaCount == 0 ? nil
            : String(localized: "\(newerSchemaCount) snippets came from a newer Keyloom. Update the app to see them.")
    }

    /// Shown when sync turned snippets off because another snippet uses their keyword.
    var keywordConflictNote: String? {
        keywordConflictCount == 0 ? nil
            : String(localized: "\(keywordConflictCount) snippets were turned off because another snippet uses the same keyword. Change a keyword to turn one back on.")
    }

    var pendingNote: String? {
        pendingChanges == 0 || !isEnabled || presentation.isUnsupportedBuild ? nil : String(localized: "\(pendingChanges) changes waiting to upload")
    }

    // MARK: Actions

    /// Follows status changes until the surrounding task is cancelled (attach with `.task`).
    func observe() async {
        for await next in await controller.statusUpdates() {
            status = next
            await refreshCounts()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        await controller.setEnabled(enabled)
        await refresh()
    }

    func syncNow() async {
        await controller.syncNow()
        await refresh()
    }

    func refresh() async {
        status = await controller.status
        isEnabled = preference.isEnabled
        await refreshCounts()
    }

    private func refreshCounts() async {
        pendingChanges = await controller.pendingChangeCount()
        skippedRemoteRecords = await controller.skippedRemoteRecords
        keywordConflictCount = await controller.keywordConflictCount()
        newerSchemaCount = await controller.newerSchemaRecordCount
    }
}
