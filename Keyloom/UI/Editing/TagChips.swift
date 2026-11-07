import SwiftUI

/// The tags row of the editor: a removable chip per tag, then an "Add tag…" field. Comma-separated input adds
/// several at once; the tags themselves stay in `draft.tagsText`.
struct TagChipsView: View {
    @Bindable var editor: EditorViewModel
    @FocusState private var adding: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(editor.draft.tags, id: \.self) { tag in
                chip(tag)
            }
            TextField("Add tag…", text: $editor.pendingTag)
                .textFieldStyle(.plain)
                .focused($adding)
                .onSubmit { editor.commitPendingTag() }
                .frame(minWidth: 90, maxWidth: 180)
                .padding(.horizontal, 4)
                .frame(minHeight: 24)
                .accessibilityLabel("Tags")
        }
        .onChange(of: adding) { _, focused in
            if !focused { editor.commitPendingTag() }
        }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 2) {
            Text(tag).lineLimit(1).padding(.leading, 8)
            Button {
                editor.removeTag(tag)
                // The chip is gone with the focus on it; the add field is the nearest stable stop.
                adding = true
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
            .help("Remove tag")
        }
        .font(.callout)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
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
