import SwiftUI

/// The tags row of the editor: a removable chip per tag, then an "Add tag…" field. Comma-separated input adds
/// several at once; the tags themselves stay in `draft.tagsText`. While the field is focused, the library's existing
/// tags the snippet lacks are offered beneath it, filtered by what is typed (click, or Down and Return, adds one);
/// anything else typed still makes a new tag. A chip's context menu picks its color (this Mac only).
struct TagChipsView: View {
    @Bindable var editor: EditorViewModel
    /// Every tag in the library, as the sidebar lists them.
    let available: [String]
    let colors: TagColors
    @FocusState private var adding: Bool
    @State private var highlighted: Int?

    private var suggestions: [String] {
        TagSuggestions.suggestions(typed: editor.pendingTag, available: available, excluding: editor.draft.tags)
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(editor.draft.tags, id: \.self) { tag in
                chip(tag)
            }
            addField
        }
        .onChange(of: adding) { _, focused in
            if !focused { editor.commitPendingTag() }
        }
        .onChange(of: editor.pendingTag) { highlighted = nil }
    }

    private var addField: some View {
        TextField("Add tag…", text: $editor.pendingTag)
            .textFieldStyle(.plain)
            .focused($adding)
            .onSubmit { submit() }
            .onKeyPress(.downArrow) { moveHighlight(1) }
            .onKeyPress(.upArrow) { moveHighlight(-1) }
            .onKeyPress(.escape) {
                guard highlighted != nil || !editor.pendingTag.isEmpty else { return .ignored }
                highlighted = nil
                editor.pendingTag = ""
                return .handled
            }
            .frame(minWidth: 90, maxWidth: 180)
            .padding(.horizontal, 4)
            .frame(minHeight: 24)
            .accessibilityLabel("Tags")
            .overlay(alignment: .topLeading) {
                if adding, !suggestions.isEmpty { suggestionList.offset(y: 28) }
            }
            .zIndex(1)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, tag in
                Button { choose(tag) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(colors.color(for: tag)?.color ?? .gray.opacity(0.5)).frame(width: 7, height: 7)
                        Text(tag).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(highlighted == index ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { colorMenu(for: tag) }
                .accessibilityLabel("Add tag \(tag)")
            }
        }
        .padding(4)
        .frame(width: 180, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Existing tags")
    }

    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        let count = suggestions.count
        guard count > 0 else { return .ignored }
        let next = (highlighted ?? (step > 0 ? -1 : count)) + step
        highlighted = min(max(next, 0), count - 1)
        return .handled
    }

    private func submit() {
        if let highlighted, suggestions.indices.contains(highlighted) {
            choose(suggestions[highlighted])
        } else {
            editor.commitPendingTag()
        }
    }

    private func choose(_ tag: String) {
        editor.pendingTag = ""
        editor.addTags(from: tag)
        highlighted = nil
        adding = true
    }

    private func chip(_ tag: String) -> some View {
        let tint = colors.color(for: tag)
        return HStack(spacing: 2) {
            if let tint { Circle().fill(tint.color).frame(width: 7, height: 7).padding(.leading, 8).accessibilityHidden(true) }
            Text(tag).lineLimit(1).padding(.leading, tint == nil ? 8 : 4)
            Button {
                editor.removeTag(tag)
                // The chip is gone with the focus on it; the add field is the nearest stable stop.
                adding = true
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
            .help("Remove tag")
        }
        .font(.system(size: 12))
        .background(tint.map { AnyShapeStyle($0.color.opacity(0.14)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
        .contextMenu { colorMenu(for: tag) }
        .accessibilityElement(children: .contain)
    }

    /// The palette as a menu of swatches; the tag's current color is checked, and choosing it again clears it.
    @ViewBuilder
    private func colorMenu(for tag: String) -> some View {
        let current = colors.color(for: tag)
        ForEach(TagColor.allCases) { color in
            Button {
                colors.set(color, for: tag)
            } label: {
                Label(color.displayName, systemImage: current == color ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundStyle(color.color)
            }
        }
        if current != nil {
            Divider()
            Button("No Color") { colors.set(nil, for: tag) }
        }
    }
}

/// Lays children out left to right and wraps to a new line when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
