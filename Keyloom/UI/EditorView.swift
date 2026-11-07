import SwiftUI

/// The detail column: an action bar while there are unsaved changes, a borderless title, keyword and tags as
/// one-line rows, the template beside (or, in a narrow column, above) its live preview, and this device's usage
/// of the snippet.
struct EditorView: View {
    @Bindable var editor: EditorViewModel
    let save: () -> Void
    /// Every tag in the library, for the suggestions under the tag field, and their device-local colors.
    let availableTags: [String]
    let tagColors: TagColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingIcons = false
    @State private var showingArgument = false
    @State private var argumentForm = ArgumentForm()
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0

    private static let labelWidth: CGFloat = 62
    /// Two panes of at least 320 pt each, the gap and the margins.
    private static let sideBySideWidth: CGFloat = 700

    private var sideBySide: Bool { width >= Self.sideBySideWidth }
    /// Side by side, the panes take the height the rows above leave, so a tall window has no empty band under them.
    private var bodyMinHeight: CGFloat {
        // Stacked, the preview keeps its own 120 pt and the gap; side by side it shares the row.
        sideBySide ? max(180, height - Self.aboveBodyHeight) : max(110, height - Self.aboveBodyHeight - 140)
    }
    /// The header, keyword and tag rows, the pane chrome (formatting and insert bars), the usage line and the margins.
    private static let aboveBodyHeight: CGFloat = 400

    /// Only while there is something to save or revert, and for a snippet that does not exist yet.
    private var showsActionBar: Bool { editor.isDirty || editor.target == .new }

    var body: some View {
        VStack(spacing: 0) {
            if showsActionBar {
                actionBar.transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showsActionBar)
        .task(id: editor.target) { await editor.refreshUsage() }
        .onChange(of: editor.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .sheet(isPresented: $showingArgument) { argumentSheet }
        .sheet(isPresented: Binding(get: { editor.assistance.map { $0.state != .idle } ?? false },
                                    set: { if !$0 { editor.assistance?.cancel() } })) {
            if let assistance = editor.assistance { AssistanceSheet(assistance: assistance) }
        }
    }

    /// 44 pt bar over the form, hairline below: the caption on the left, Revert and the one prominent Save on the
    /// right. Command-S is the Save Snippet menu command.
    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(editor.dirtyCaption ?? "New snippet · not saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("editor.dirtyCaption")
                Spacer(minLength: 8)
                if editor.isDirty {
                    Button("Revert") { editor.revert() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .help("Discard the changes since the last save")
                        .accessibilityIdentifier("editor.revert")
                }
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text("Save").fontWeight(.medium)
                        Text("⌘S")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 4)
                            .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!editor.canSave)
                .help("Save this snippet (Command-S)")
                .accessibilityLabel("Save")
                .accessibilityIdentifier("editor.save")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                keywordSection
                // Above the panes, so the tag suggestions drop over them.
                tagsRow.zIndex(1)
                panes
                if let keyword = editor.typedAnywhereKeyword { typedAnywhereLine(keyword) }
                Text(editor.usageLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("editor.usage")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
    }

    // MARK: Header and rows

    private var header: some View {
        HStack(spacing: 12) {
            Button { showingIcons = true } label: {
                SnippetIconTile(icon: editor.draft.icon, size: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Icon")
            .accessibilityValue(editor.draft.icon.spoken)
            .help("Choose an icon")
            .popover(isPresented: $showingIcons) { IconPickerView(icon: $editor.draft.icon) }
            TextField("Name", text: $editor.draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.2)
                .accessibilityLabel("Snippet name")
                .accessibilityIdentifier("editor.name")
        }
    }

    private var keywordSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rowLabel("Keyword")
                    keywordField
                    keywordPill
                    Spacer(minLength: 8)
                    expandToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        rowLabel("Keyword")
                        keywordField
                        keywordPill
                    }
                    expandToggle.padding(.leading, Self.labelWidth + 10)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let hint = editor.keywordHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                ForEach(editor.keywordFeedback.conflicts, id: \.self) { message in
                    Label(message + " Change the keyword or turn off Expand automatically to save.", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(editor.keywordFeedback.warnings, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            // One caption line is always reserved, so a verdict appearing does not shift the rows below.
            .frame(minHeight: 16, alignment: .topLeading)
            .padding(.leading, Self.labelWidth + 10)
        }
        .task(id: KeywordKey(keyword: editor.draft.keyword, enabled: editor.draft.enabled)) {
            await editor.refreshKeywordFeedback()
        }
    }

    private func typedAnywhereLine(_ keyword: String) -> some View {
        HStack(spacing: 6) {
            Text("Typed anywhere:")
            KeywordChip(keyword: keyword)
            Text("→ expands in place.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typed anywhere: \(keyword) expands in place.")
        .accessibilityIdentifier("editor.typedAnywhere")
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
    }

    private var keywordField: some View {
        TextField("::keyword", text: $editor.draft.keyword)
            .textFieldStyle(.plain)
            .font(.body.monospaced())
            .fieldBackground()
            .frame(minWidth: 150, idealWidth: 150, maxWidth: 240)
            .fixedSize(horizontal: false, vertical: true)
            // A keyword is typed without gaps; the library rejects whitespace anyway.
            .onChange(of: editor.draft.keyword) { _, value in
                let cleaned = SnippetDraft.sanitizedKeyword(value)
                if cleaned != value { editor.draft.keyword = cleaned }
            }
            .accessibilityLabel("Expansion keyword")
    }

    @ViewBuilder
    private var keywordPill: some View {
        let status = editor.keywordStatus
        if let title = status.title {
            let tint: Color = switch status {
            case .free: .green
            case .conflict: .red
            case .overlap: .orange
            default: .secondary
            }
            Label(title, systemImage: status.symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(tint.opacity(0.16), in: Capsule())
                .fixedSize()
                .accessibilityIdentifier("editor.keywordStatus")
        }
    }

    private var expandToggle: some View {
        HStack(spacing: 8) {
            Text("Expand automatically").foregroundStyle(.secondary).lineLimit(1)
            Toggle("Expand automatically", isOn: $editor.draft.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .fixedSize()
    }

    private var tagsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            rowLabel("Tags")
            TagChipsView(editor: editor, available: availableTags, colors: tagColors)
        }
    }

    // MARK: Template and result

    /// One layout that switches axis, never an if/else: a branch change would rebuild the body's NSTextView, which
    /// then comes up empty.
    private var panes: some View {
        let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return layout {
            templatePane.frame(maxWidth: .infinity)
            expandsToPane.frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var templatePane: some View {
        VStack(spacing: 0) {
            formattingBar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            RichTextView(controller: editor.bodyController)
                .frame(minHeight: bodyMinHeight)
            tokenBar
        }
        .paneChrome()
    }

    /// The full bar when it fits; otherwise the placeholder and rewrite menus shrink to their icons, so nothing is clipped.
    private var formattingBar: some View {
        ViewThatFits(in: .horizontal) {
            formattingBar(compact: false)
            formattingBar(compact: true)
        }
    }

    private func formattingBar(compact: Bool) -> some View {
        HStack(spacing: 6) {
            styleToggle("Bold", systemImage: "bold", style: .bold, key: "b")
            styleToggle("Italic", systemImage: "italic", style: .italic, key: "i")
            styleToggle("Underline", systemImage: "underline", style: .underline, key: "u")
            Divider().frame(height: 18)
            kindToggle("Paragraph", systemImage: "text.alignleft", kind: .plain)
            kindToggle("Numbered List", systemImage: "list.number", kind: .numbered)
            kindToggle("Bulleted List", systemImage: "list.bullet", kind: .bullet)
            Spacer(minLength: 0)
            Menu {
                placeholderButton("Date", .date(format: nil))
                placeholderButton("Date as yyyy-MM-dd", .date(format: "yyyy-MM-dd"))
                placeholderButton("Time", .time(format: nil))
                placeholderButton("UUID", .uuid)
                placeholderButton("Clipboard", .clipboard)
                placeholderButton("Cursor Position", .cursor).disabled(editor.bodyController.hasCursorToken)
                Divider()
                Button("Argument…") { beginArgument() }
            } label: {
                Label("Insert Placeholder", systemImage: "curlybraces")
            }
            .menuStyle(.borderlessButton)
            .compactLabel(compact)
            .help("Insert Placeholder")
            .fixedSize()
            if let assistance = editor.assistance, assistance.isOffered { AssistanceMenu(assistance: assistance, compact: compact) }
        }
    }

    /// One click per placeholder, drawn as the pill it becomes. Hidden when the pane is too narrow; the Insert
    /// Placeholder menu above always has the same items.
    private var tokenBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("Insert").font(.caption).foregroundStyle(.secondary)
                tokenButton("{argument}", help: "Insert an argument you fill in when it expands") { beginArgument() }
                tokenButton("{date}", help: "Insert today’s date") { insert(.date(format: nil)) }
                tokenButton("{time}", help: "Insert the current time") { insert(.time(format: nil)) }
                tokenButton("{clipboard}", help: "Insert the clipboard text") { insert(.clipboard) }
                tokenButton("{cursor}", help: "Place the cursor after expansion") { insert(.cursor) }
                    .disabled(editor.bodyController.hasCursorToken)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            Color.clear.frame(height: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insert placeholder")
    }

    private func tokenButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TokenPill.fontSize, design: .monospaced))
                .foregroundStyle(Color(nsColor: TokenPill.text))
                .padding(.horizontal, 5)
                .background(Color(nsColor: TokenPill.fill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Insert \(title)")
    }

    private func beginArgument() {
        argumentForm = ArgumentForm()
        showingArgument = true
    }

    private func styleToggle(_ title: String, systemImage: String, style: TextStyle, key: KeyEquivalent) -> some View {
        Toggle(isOn: Binding(get: { editor.bodyController.activeStyles.contains(style) }, set: { _ in editor.bodyController.toggle(style) })) {
            Image(systemName: systemImage)
        }
        .toggleStyle(FormatToggleStyle())
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityLabel(title)
        .help(title)
    }

    private func kindToggle(_ title: String, systemImage: String, kind: ParagraphKind) -> some View {
        Toggle(isOn: Binding(get: { editor.bodyController.activeKind == kind }, set: { _ in editor.bodyController.setKind(kind) })) {
            Image(systemName: systemImage)
        }
        .toggleStyle(FormatToggleStyle())
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

    private var expandsToPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ForEach(editor.argumentRequirements, id: \.name) { requirement in
                sampleField(requirement)
            }
            switch editor.preview {
            case .rendered(let rendered):
                Text(PreviewText.attributed(rendered))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .paneChrome()
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
            .font(.callout)
        } else {
            Picker("Sample for \(requirement.name)", selection: sample) {
                ForEach(requirement.choices, id: \.self) { Text($0).tag($0) }
            }
            .font(.callout)
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

/// A quiet square toggle for the formatting bar: no fill until hovered, a tinted fill when on.
private struct FormatToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        FormatToggleBody(configuration: configuration)
    }

    private struct FormatToggleBody: View {
        let configuration: ToggleStyleConfiguration
        @State private var hovering = false

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                configuration.label
                    .font(.system(size: 13))
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.75))
                    .frame(width: 28, height: 24)
                    .background(configuration.isOn ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        }
    }
}

private struct KeywordKey: Hashable {
    let keyword: String
    let enabled: Bool
}

private extension View {
    /// A single-line field on a quiet rounded fill, like the keyword value in the mock.
    func fieldBackground() -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The rounded, hairline-bordered frame shared by the template and result panes.
    func paneChrome() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
    }
}
