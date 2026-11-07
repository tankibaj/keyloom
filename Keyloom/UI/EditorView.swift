import SwiftUI

/// The detail column: name, icon, keyword, tags, formatted body with its toolbar, and the live preview.
struct EditorView: View {
    @Bindable var editor: EditorViewModel
    @State private var showingIcons = false
    @State private var showingArgument = false
    @State private var argumentForm = ArgumentForm()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                fields
                formattingBar
                RichTextView(controller: editor.bodyController)
                    .frame(minHeight: 200)
                preview
            }
            .padding(20)
        }
        .onChange(of: editor.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .sheet(isPresented: $showingArgument) { argumentSheet }
        .sheet(isPresented: Binding(get: { editor.assistance.map { $0.state != .idle } ?? false },
                                    set: { if !$0 { editor.assistance?.cancel() } })) {
            if let assistance = editor.assistance { AssistanceSheet(assistance: assistance) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showingIcons = true } label: {
                SnippetIconView(icon: editor.draft.icon).font(.largeTitle).frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Icon")
            .accessibilityValue(editor.draft.icon.spoken)
            .help("Choose an icon")
            .popover(isPresented: $showingIcons) { IconPickerView(icon: $editor.draft.icon) }
            TextField("Name", text: $editor.draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .accessibilityLabel("Snippet name")
                .accessibilityIdentifier("editor.name")
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Keyword").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("::keyword", text: $editor.draft.keyword)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Expansion keyword")
                        Toggle("Expand automatically", isOn: $editor.draft.enabled)
                    }
                    if let hint = editor.keywordHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                    ForEach(editor.keywordFeedback.conflicts, id: \.self) { message in
                        Label(message + " Change the keyword or turn off Expand automatically to save.", systemImage: "exclamationmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    ForEach(editor.keywordFeedback.warnings, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .task(id: KeywordKey(keyword: editor.draft.keyword, enabled: editor.draft.enabled)) {
                    await editor.refreshKeywordFeedback()
                }
            }
            GridRow {
                Text("Tags")
                TextField("Separate tags with commas", text: $editor.draft.tagsText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Tags")
            }
        }
    }

    private var formattingBar: some View {
        HStack(spacing: 6) {
            styleToggle("Bold", systemImage: "bold", style: .bold, key: "b")
            styleToggle("Italic", systemImage: "italic", style: .italic, key: "i")
            styleToggle("Underline", systemImage: "underline", style: .underline, key: "u")
            Divider().frame(height: 18)
            kindToggle("Paragraph", systemImage: "text.alignleft", kind: .plain)
            kindToggle("Numbered List", systemImage: "list.number", kind: .numbered)
            kindToggle("Bulleted List", systemImage: "list.bullet", kind: .bullet)
            Spacer()
            Menu {
                placeholderButton("Date", .date(format: nil))
                placeholderButton("Date as yyyy-MM-dd", .date(format: "yyyy-MM-dd"))
                placeholderButton("Time", .time(format: nil))
                placeholderButton("UUID", .uuid)
                placeholderButton("Clipboard", .clipboard)
                placeholderButton("Cursor Position", .cursor).disabled(editor.bodyController.hasCursorToken)
                Divider()
                Button("Argument…") {
                    argumentForm = ArgumentForm()
                    showingArgument = true
                }
            } label: {
                Label("Insert Placeholder", systemImage: "curlybraces")
            }
            .fixedSize()
            if let assistance = editor.assistance, assistance.isOffered { AssistanceMenu(assistance: assistance) }
        }
    }

    private func styleToggle(_ title: String, systemImage: String, style: TextStyle, key: KeyEquivalent) -> some View {
        Toggle(isOn: Binding(get: { editor.bodyController.activeStyles.contains(style) }, set: { _ in editor.bodyController.toggle(style) })) {
            Image(systemName: systemImage).frame(minWidth: 20)
        }
        .toggleStyle(.button)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityLabel(title)
        .help(title)
    }

    private func kindToggle(_ title: String, systemImage: String, kind: ParagraphKind) -> some View {
        Toggle(isOn: Binding(get: { editor.bodyController.activeKind == kind }, set: { _ in editor.bodyController.setKind(kind) })) {
            Image(systemName: systemImage).frame(minWidth: 20)
        }
        .toggleStyle(.button)
        .accessibilityLabel(title)
        .help(title)
    }

    private func placeholderButton(_ title: String, _ placeholder: Placeholder) -> some View {
        Button(title) { insert(placeholder) }
    }

    private func insert(_ placeholder: Placeholder) {
        do {
            editor.bodyController.insert(tokenSource: try placeholder.source())
        } catch {
            editor.errorMessage = UserMessage.describe(error)
        }
    }

    private var preview: some View {
        GroupBox("Preview and Try Expansion") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(editor.argumentRequirements, id: \.name) { requirement in
                    sampleField(requirement)
                }
                switch editor.preview {
                case .rendered(let rendered):
                    Text(PreviewText.attributed(rendered)).textSelection(.enabled)
                case .unavailable(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview and Try Expansion")
    }

    /// A choice list for arguments with options, free text otherwise; the value is a sample and is never saved.
    @ViewBuilder
    private func sampleField(_ requirement: ArgumentRequirement) -> some View {
        let sample = Binding(
            get: { editor.sampleArguments[requirement.name] ?? requirement.defaultValue ?? requirement.choices.first ?? "" },
            set: { editor.sampleArguments[requirement.name] = $0 })
        // A visible label (a bare prompt disappears once the field has text) and the same name for VoiceOver.
        if requirement.choices.isEmpty {
            LabeledContent("Sample for \(requirement.name)") {
                TextField("Sample for \(requirement.name)", text: sample, prompt: Text("‹\(requirement.name)›"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Sample for \(requirement.name)")
            }
        } else {
            Picker("Sample for \(requirement.name)", selection: sample) {
                ForEach(requirement.choices, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityLabel("Sample for \(requirement.name)")
        }
    }

    private var argumentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Argument").font(.headline)
            Form {
                TextField("Name", text: $argumentForm.name)
                TextField("Default value", text: $argumentForm.defaultValue)
                TextField("Choices, separated by commas", text: $argumentForm.choicesText)
            }
            if let message = editor.errorMessage { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingArgument = false }.keyboardShortcut(.cancelAction)
                Button("Insert") {
                    guard let placeholder = argumentForm.placeholder else { return }
                    insert(placeholder)
                    if editor.errorMessage == nil { showingArgument = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(argumentForm.placeholder == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct KeywordKey: Hashable {
    let keyword: String
    let enabled: Bool
}
