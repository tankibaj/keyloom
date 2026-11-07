import SwiftUI

/// User-facing text for the Settings panel. Unavailable reasons come only from what macOS exposes: the
/// wording never mentions an administrator or a restriction, because a generic status does not say why.
enum AssistanceCopy {
    static func assistanceStatus(_ state: AssistanceState) -> String {
        switch state {
        case .off:
            "Off. Keyloom never starts the on-device model."
        case .ready:
            "Ready. Select text in a snippet and choose an action to get a suggestion you can review."
        case .unavailable(.deviceNotEligible):
            "Unavailable: macOS reports that this Mac is not eligible for the on-device model."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Unavailable: macOS reports that Apple Intelligence is not turned on."
        case .unavailable(.unspecified):
            "Unavailable: macOS reports the on-device model as unavailable and gives no reason."
        case .downloading:
            "Not ready yet: macOS reports the on-device model is not ready, and it may still be downloading."
        case .unsupportedLanguage:
            "Unavailable: macOS reports that the on-device model does not support the current language."
        case .managedOff:
            "Turned off by your organization on this Mac."
        }
    }

    static func writingToolsStatus(_ state: WritingToolsState) -> String {
        switch state {
        case .off:
            "Off. Writing Tools are disabled in Keyloom's text fields."
        case .allowed:
            "On. Writing Tools can appear in snippet text fields, if macOS makes them available."
        case .managedOff:
            "Turned off by your organization on this Mac."
        }
    }

    static let assistanceExplanation =
        "Proofread, shorten or change the tone of the text you select, using Apple's on-device model. "
        + "Only the selected words are used. Placeholders such as {clipboard} are never filled in or changed, "
        + "and you review every suggestion before it is applied."

    static let writingToolsDisclosure =
        "Apple manages system Writing Tools and decides where they are available. "
        + "If you choose an external integration inside Writing Tools, that integration may send the selected text to its service."

    static let deviceOnlyNote = "These settings apply to this Mac only and are never synced."
}

/// Backs `WritingAssistanceSettingsView`. Toggles write straight through to the policy, which persists them.
@MainActor
@Observable
final class WritingAssistanceSettingsModel {
    private let policy: WritingAssistancePolicy

    init(policy: WritingAssistancePolicy) { self.policy = policy }

    var assistanceEnabled: Bool {
        get { policy.isAssistanceEnabled }
        set { policy.setAssistanceEnabled(newValue) }
    }

    var systemWritingToolsEnabled: Bool {
        get { policy.isSystemWritingToolsEnabled }
        set { policy.setSystemWritingToolsEnabled(newValue) }
    }

    /// Both toggles are disabled while the organization forces assistance off.
    var togglesLocked: Bool { policy.snapshot.managed == .forbidden }

    var assistanceStatus: String { AssistanceCopy.assistanceStatus(policy.snapshot.assistance) }
    var writingToolsStatus: String { AssistanceCopy.writingToolsStatus(policy.snapshot.writingTools) }

    func refresh() { policy.refresh() }
}

/// The Settings panel for optional writing assistance. WP4 hosts it in the app's Settings scene.
struct WritingAssistanceSettingsView: View {
    @Bindable var model: WritingAssistanceSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Use on-device writing assistance", isOn: $model.assistanceEnabled)
                    .disabled(model.togglesLocked)
                Text(AssistanceCopy.assistanceExplanation).foregroundStyle(.secondary)
                Text(model.assistanceStatus)
            } header: {
                Text("On-device assistance")
            }
            Section {
                Toggle("Allow system Writing Tools", isOn: $model.systemWritingToolsEnabled)
                    .disabled(model.togglesLocked)
                Text(AssistanceCopy.writingToolsDisclosure).foregroundStyle(.secondary)
                Text(model.writingToolsStatus)
            } header: {
                Text("System Writing Tools")
            }
            Section {
                Text(AssistanceCopy.deviceOnlyNote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }
}
