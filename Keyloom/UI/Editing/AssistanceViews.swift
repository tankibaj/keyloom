import SwiftUI

/// Proofread, Shorten and Change Tone for the selected words. Shown only while on-device assistance is on and
/// ready; items stay disabled until some text is selected.
struct AssistanceMenu: View {
    let assistance: AssistanceEditorModel
    /// Icon only, for a narrow editor; the accessibility name and tooltip stay.
    var compact = false

    var body: some View {
        Menu {
            Button("Proofread") { run(.proofread) }
            Button("Shorten") { run(.shorten) }
            Menu("Change Tone") {
                ForEach(EditTone.allCases, id: \.self) { tone in
                    Button(tone.rawValue.capitalized) { run(.changeTone(tone)) }
                }
            }
        } label: {
            Label("Rewrite Selection", systemImage: "wand.and.stars")
        }
        .menuStyle(.borderlessButton)
        .compactLabel(compact)
        .fixedSize()
        .disabled(!assistance.canRequest)
        .help(assistance.canRequest ? "Proofread, shorten or change the tone of the selected words" : "Select some words first")
        .accessibilityIdentifier("editor.assistance.menu")
    }

    private func run(_ action: EditAction) { Task { await assistance.request(action) } }
}

/// The preview: what would change, with Apply and Cancel. Escape cancels; nothing changes until Apply.
struct AssistanceSheet: View {
    let assistance: AssistanceEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestion").font(.headline).accessibilityAddTraits(.isHeader)
            switch assistance.state {
            case .idle:
                EmptyView()
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the on-device model…")
                }
                .accessibilityElement(children: .combine)
            case .proposed(let preview):
                comparison(preview)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("editor.assistance.message")
            }
            HStack {
                Spacer()
                switch assistance.state {
                case .failed:
                    Button("OK") { assistance.dismissFailure() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("editor.assistance.dismiss")
                default:
                    Button("Cancel") { assistance.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("editor.assistance.cancel")
                    Button("Apply") { Task { await assistance.apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!assistance.canApply)
                        .accessibilityIdentifier("editor.assistance.apply")
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: assistance.state) { _, state in
            if case .failed(let message) = state { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func comparison(_ preview: EditPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Selected") { Text(preview.originalText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            GroupBox("Suggested") { Text(preview.proposedText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            if preview.originalText == preview.proposedText {
                Label("The model suggests no change.", systemImage: "checkmark.circle")
            }
            Text("Placeholders stay exactly as they are. Apply is one step you can undo with Edit > Undo.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
