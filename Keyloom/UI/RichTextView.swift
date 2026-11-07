import AppKit
import SwiftUI

/// The editing surface: a plain, opaque NSTextView (system text colors, no custom chrome) so body text stays legible
/// under Reduce Transparency and Increase Contrast. Rich text from other apps is pasted as plain text.
final class BodyTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// A scroll view whose text view always fills the visible area, so a click below the last line lands in the text view
/// (and places the caret at the end) instead of on dead space.
final class FillingScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let visible = contentSize.height
        if textView.minSize.height != visible {
            textView.minSize = NSSize(width: 0, height: visible)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if textView.frame.height < visible { textView.setFrameSize(NSSize(width: textView.frame.width, height: visible)) }
        }
    }
}

struct RichTextView: NSViewRepresentable {
    let controller: RichTextController

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(controller: controller) }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    /// Writing Tools stay off (`.none`) until `controller.writingToolsBehavior` says otherwise, which only the
    /// assistance policy does.
    static func makeScrollView(controller: RichTextController) -> NSScrollView {
        let textView = BodyTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = true
        textView.allowsUndo = true
        textView.writingToolsBehavior = .none
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Snippet body")
        let scroll = FillingScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder   // the editor pane draws its own rounded border
        controller.attach(textView)
        return scroll
    }
}
