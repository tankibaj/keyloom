import AppKit
import SwiftUI

/// The named-argument prompt: one control per distinct name (a menu for choices, a text field otherwise),
/// defaults prefilled, Cancel and Insert. Return confirms and Escape cancels.
struct ArgumentPromptView: View {
    @Bindable var model: ArgumentPromptModel
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Form {
                ForEach(model.fields) { field in
                    if field.isChoice {
                        Picker(field.name, selection: binding(for: field)) {
                            ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("prompt.field.\(field.name)")
                    } else {
                        TextField(field.name, text: binding(for: field))
                            .focused($focusedField, equals: field.name)
                            .onSubmit { model.confirm() }
                            .accessibilityIdentifier("prompt.field.\(field.name)")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("prompt.cancel")
                Button("Insert") { model.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm)
                    .accessibilityIdentifier("prompt.confirm")
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focusedField = model.fields.first { !$0.isChoice }?.name }
    }

    private func binding(for field: ArgumentPromptModel.Field) -> Binding<String> {
        Binding(get: { model.fields.first { $0.name == field.name }?.value ?? "" },
                set: { model.setValue($0, for: field.name) })
    }
}

/// A key-capable panel that does not take over as the main window; shared by the prompt and the picker.
final class FloatingPanel: NSPanel {
    /// Escape in a field without a Cancel button.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

/// Shows the prompt in a floating panel over whatever app the user is in. Closing the window by any route
/// counts as Cancel, so the host is never left waiting.
@MainActor
final class PromptPanelPresenter: NSObject, PromptPresenting, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var model: ArgumentPromptModel?

    func show(_ model: ArgumentPromptModel) {
        self.model = model
        let host = NSHostingView(rootView: ArgumentPromptView(model: model))
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.contentView = host
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel(model.title)
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        let closing = panel
        panel = nil
        model = nil
        closing?.delegate = nil
        closing?.close()
    }

    func windowWillClose(_ notification: Notification) { model?.cancel() }
}
