import Foundation
import Observation

/// What the iCloud Sync section can show. `off` is the user's choice; the rest are conditions reported by the
/// provider. None of them blocks local editing, expansion or backups.
enum SyncStatus: Equatable, CaseIterable {
    case off, signedOut, unavailable, quota, syncing, upToDate, error
}

/// The seam between Settings and iCloud sync. The Settings view renders this and nothing else, so the CloudKit
/// provider (Keyloom/Sync, WP5) plugs in without touching the view. The switch is per Mac and off by default;
/// per-device assistance keys never pass through this type.
@MainActor
protocol SyncSettingsProviding: AnyObject, Observable {
    var isEnabled: Bool { get }
    var status: SyncStatus { get }
    func setEnabled(_ enabled: Bool)
}

/// Until the sync engine is merged: remembers the switch on this Mac and says sync is not available yet.
@MainActor @Observable
final class LocalOnlySyncSettings: SyncSettingsProviding {
    static let key = "keyloom.sync.enabled"

    private(set) var isEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key)
    }

    var status: SyncStatus { isEnabled ? .unavailable : .off }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.key)
    }
}

/// Words and symbols for each status. Every state has text as well as an icon, so color never carries it alone.
enum SyncCopy {
    static func description(for status: SyncStatus) -> String {
        switch status {
        case .off:
            "Off. Your snippets stay on this Mac. Turn this on to keep them in sync through your private iCloud."
        case .signedOut:
            "Sign in to iCloud in System Settings to sync. Your snippets keep working on this Mac."
        case .unavailable:
            "iCloud sync isn’t available on this Mac right now. Your snippets keep working locally."
        case .quota:
            "Your iCloud storage is full, so changes aren’t syncing. Free up iCloud storage to resume."
        case .syncing:
            "Syncing your snippets…"
        case .upToDate:
            "Up to date. Changes sync through your private iCloud."
        case .error:
            "Sync stopped because of an error. Your snippets are safe on this Mac."
        }
    }

    static func symbol(for status: SyncStatus) -> String {
        switch status {
        case .off: "icloud"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "icloud.slash"
        case .quota: "xmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .error: "exclamationmark.icloud"
        }
    }
}
