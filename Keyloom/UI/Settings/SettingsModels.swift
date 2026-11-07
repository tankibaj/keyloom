import Foundation

/// Everything the Settings scene shows, built once the library and the host exist.
@MainActor
struct SettingsModels {
    let appearance: AppearanceSettings
    let shortcut: ShortcutSettingsModel
    let expansion: ExpansionSettingsModel
    let backups: SyncBackupsModel
    let sync: any SyncSettingsProviding
    let assistance: WritingAssistanceSettingsModel
}
